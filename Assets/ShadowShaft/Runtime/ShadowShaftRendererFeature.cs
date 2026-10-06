using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.RenderGraphModule;
using UnityEngine.Rendering.Universal;

namespace ShadowShaft
{
    /// <summary>
    /// レイマーチングでライトの影を空間中に積算し、影の帯として画面を暗くするポストエフェクト。
    /// </summary>
    public sealed class ShadowShaftRendererFeature : ScriptableRendererFeature
    {
        /// <summary>影を積算する追加ライトの上限 (シェーダーの MAX_SHADOW_SHAFT_LIGHTS と合わせる)</summary>
        public const int k_MaxAdditionalLights = 8;

        [SerializeField] Shader shader;
        [SerializeField] RenderPassEvent renderPassEvent = RenderPassEvent.BeforeRenderingTransparents;

        Material m_Material;
        ShadowShaftPass m_Pass;

        public override void Create()
        {
            if (shader == null)
                shader = Shader.Find("Hidden/ShadowShaft");

            m_Pass = new ShadowShaftPass();
        }

        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            var cameraType = renderingData.cameraData.cameraType;
            if (cameraType == CameraType.Preview || cameraType == CameraType.Reflection)
                return;

            if (shader == null)
                return;

            if (m_Material == null)
                m_Material = CoreUtils.CreateEngineMaterial(shader);

            var volume = VolumeManager.instance.stack.GetComponent<ShadowShaftVolume>();
            if (volume == null || !volume.IsActive())
                return;

            m_Pass.renderPassEvent = renderPassEvent;
            m_Pass.Setup(m_Material, volume);
            renderer.EnqueuePass(m_Pass);
        }

        protected override void Dispose(bool disposing)
        {
            CoreUtils.Destroy(m_Material);
            m_Material = null;
        }

        sealed class ShadowShaftPass : ScriptableRenderPass
        {
            const int k_RaymarchPass = 0;
            const int k_BlurPass = 1;
            const int k_CompositePass = 2;
            const int k_BlurHorizontalPass = 3;
            const int k_BlurVerticalPass = 4;

            static readonly int s_ShadowShaftBlurTexture = Shader.PropertyToID("_ShadowShaftBlurTexture");
            static readonly int s_ShadowShaftTexelSize = Shader.PropertyToID("_ShadowShaftTexelSize");
            static readonly int s_Intensity = Shader.PropertyToID("_Intensity");
            static readonly int s_MaxDarkness = Shader.PropertyToID("_MaxDarkness");
            static readonly int s_ShadowColor = Shader.PropertyToID("_ShadowColor");
            static readonly int s_Density = Shader.PropertyToID("_Density");
            static readonly int s_MaxDistance = Shader.PropertyToID("_MaxDistance");
            static readonly int s_StepCount = Shader.PropertyToID("_StepCount");
            static readonly int s_DepthThreshold = Shader.PropertyToID("_DepthThreshold");
            static readonly int s_DistanceFadeStart = Shader.PropertyToID("_DistanceFadeStart");
            static readonly int s_Threshold = Shader.PropertyToID("_Threshold");
            static readonly int s_Softness = Shader.PropertyToID("_Softness");
            static readonly int s_Bands = Shader.PropertyToID("_Bands");
            static readonly int s_MainLightWeight = Shader.PropertyToID("_MainLightWeight");
            static readonly int s_AdditionalLightWeight = Shader.PropertyToID("_AdditionalLightWeight");
            static readonly int s_ShadowShaftLightCount = Shader.PropertyToID("_ShadowShaftLightCount");
            static readonly int s_ShadowShaftLightIndices = Shader.PropertyToID("_ShadowShaftLightIndices");

            Material m_Material;
            ShadowShaftVolume m_Volume;

            readonly float[] m_LightIndices = new float[k_MaxAdditionalLights];
            readonly List<LightCandidate> m_LightCandidates = new List<LightCandidate>();

            struct LightCandidate
            {
                public int additionalLightIndex;
                public float distance;
            }

            class RaymarchPassData
            {
                public Material material;
            }

            class BlurPassData
            {
                public Material material;
                public TextureHandle source;
                public int shaderPass;
            }

            class CompositePassData
            {
                public Material material;
                public TextureHandle source;
                public TextureHandle shadowShaft;
            }

            public ShadowShaftPass()
            {
                profilingSampler = new ProfilingSampler("ShadowShaft");
                requiresIntermediateTexture = true;
                ConfigureInput(ScriptableRenderPassInput.Depth);
            }

            public void Setup(Material material, ShadowShaftVolume volume)
            {
                m_Material = material;
                m_Volume = volume;
            }

            // 影を積算するスポット / ポイントライトを選び、URP の追加ライトインデックスをシェーダーに渡す
            // Forward+ のクラスタは表面のピクセル基準でライトを絞るため、レイ上の各点には使えない
            void SetupAdditionalLights(UniversalLightData lightData, UniversalCameraData cameraData)
            {
                m_LightCandidates.Clear();

                var visibleLights = lightData.visibleLights;
                int maxVisibleAdditionalLights = UniversalRenderPipeline.maxVisibleAdditionalLights;
                Vector3 cameraPosition = cameraData.worldSpaceCameraPos;

                // URP は可視ライトのうちメインライトを除いた順に追加ライトインデックスを振る (ForwardLights と同じ規則)
                int additionalLightIndex = 0;
                for (int i = 0; i < visibleLights.Length && additionalLightIndex < maxVisibleAdditionalLights; i++)
                {
                    if (i == lightData.mainLightIndex)
                        continue;

                    int index = additionalLightIndex++;
                    var visibleLight = visibleLights[i];
                    if (visibleLight.lightType != LightType.Spot && visibleLight.lightType != LightType.Point)
                        continue;

                    var light = visibleLight.light;
                    if (light == null || light.shadows == LightShadows.None || light.shadowStrength <= 0f)
                        continue;

                    // ライトの範囲 (球) の表面までの距離が近いものを優先する
                    Vector3 lightPosition = visibleLight.localToWorldMatrix.GetColumn(3);
                    float distance = Mathf.Max(0f, Vector3.Distance(cameraPosition, lightPosition) - visibleLight.range);
                    m_LightCandidates.Add(new LightCandidate { additionalLightIndex = index, distance = distance });
                }

                m_LightCandidates.Sort((a, b) => a.distance.CompareTo(b.distance));

                int lightCount = Mathf.Min(m_LightCandidates.Count, m_Volume.maxAdditionalLights.value, k_MaxAdditionalLights);
                for (int i = 0; i < k_MaxAdditionalLights; i++)
                    m_LightIndices[i] = i < lightCount ? m_LightCandidates[i].additionalLightIndex : 0f;

                m_Material.SetInt(s_ShadowShaftLightCount, lightCount);
                m_Material.SetFloatArray(s_ShadowShaftLightIndices, m_LightIndices);
            }

            public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
            {
                var resourceData = frameData.Get<UniversalResourceData>();
                var cameraData = frameData.Get<UniversalCameraData>();

                if (resourceData.isActiveTargetBackBuffer)
                    return;

                // Shadow Distance より先は影情報がないので、そこまでで打ち切る
                float maxDistance = m_Volume.maxDistance.value;
                if (cameraData.maxShadowDistance > 0f)
                    maxDistance = Mathf.Min(maxDistance, cameraData.maxShadowDistance);

                m_Material.SetFloat(s_Intensity, m_Volume.intensity.value);
                m_Material.SetFloat(s_MaxDarkness, m_Volume.maxDarkness.value);
                m_Material.SetColor(s_ShadowColor, m_Volume.shadowColor.value);
                m_Material.SetFloat(s_Threshold, m_Volume.threshold.value);
                m_Material.SetFloat(s_Softness, m_Volume.softness.value);
                m_Material.SetInt(s_Bands, m_Volume.bands.value);
                m_Material.SetFloat(s_Density, m_Volume.density.value);
                m_Material.SetFloat(s_MaxDistance, maxDistance);
                m_Material.SetFloat(s_DistanceFadeStart, maxDistance * (1f - m_Volume.distanceFade.value));
                m_Material.SetInt(s_StepCount, m_Volume.stepCount.value);
                m_Material.SetFloat(s_DepthThreshold, m_Volume.depthThreshold.value);
                m_Material.SetFloat(s_MainLightWeight, m_Volume.mainLightWeight.value);
                m_Material.SetFloat(s_AdditionalLightWeight, m_Volume.additionalLightWeight.value);
                SetupAdditionalLights(frameData.Get<UniversalLightData>(), cameraData);

                var colorDesc = renderGraph.GetTextureDesc(resourceData.cameraColor);

                // レイマーチングとブラーは縮小解像度で行い、合成時に深度を見ながら拡大する
                int downsample = (int)m_Volume.resolution.value;
                int shaftWidth = Mathf.Max(1, colorDesc.width / downsample);
                int shaftHeight = Mathf.Max(1, colorDesc.height / downsample);
                m_Material.SetVector(s_ShadowShaftTexelSize, new Vector4(1f / shaftWidth, 1f / shaftHeight, shaftWidth, shaftHeight));

                var shaftDesc = colorDesc;
                shaftDesc.name = "_ShadowShaftTexture";
                shaftDesc.sizeMode = TextureSizeMode.Explicit;
                shaftDesc.width = shaftWidth;
                shaftDesc.height = shaftHeight;
                shaftDesc.format = GraphicsFormat.R16_SFloat;
                shaftDesc.filterMode = FilterMode.Point;
                shaftDesc.clearBuffer = false;
                shaftDesc.msaaSamples = MSAASamples.None;
                TextureHandle shadowShaft = renderGraph.CreateTexture(shaftDesc);

                // ① レイマーチングで影の濃さを求める
                using (var builder = renderGraph.AddRasterRenderPass<RaymarchPassData>("ShadowShaft Raymarch", out var passData, profilingSampler))
                {
                    passData.material = m_Material;

                    builder.UseTexture(resourceData.cameraDepthTexture);
                    if (resourceData.mainShadowsTexture.IsValid())
                        builder.UseTexture(resourceData.mainShadowsTexture);
                    if (resourceData.additionalShadowsTexture.IsValid())
                        builder.UseTexture(resourceData.additionalShadowsTexture);
                    builder.SetRenderAttachment(shadowShaft, 0, AccessFlags.Write);

                    builder.SetRenderFunc((RaymarchPassData data, RasterGraphContext context) =>
                    {
                        Blitter.BlitTexture(context.cmd, new Vector4(1f, 1f, 0f, 0f), data.material, k_RaymarchPass);
                    });
                }

                // ② 4x4 タイル分を平均して、インターリーブドサンプリングのずらしを打ち消す
                var blurDesc = shaftDesc;
                blurDesc.name = "_ShadowShaftBlurTexture";
                TextureHandle shadowShaftBlur = renderGraph.CreateTexture(blurDesc);

                AddBlurPass(renderGraph, resourceData, "ShadowShaft Blur", shadowShaft, shadowShaftBlur, k_BlurPass);

                // ②' 追加のぼかし。2 枚のテクスチャを往復させ、結果は常に shadowShaftBlur に残す
                for (int i = 0; i < m_Volume.blurIterations.value; i++)
                {
                    AddBlurPass(renderGraph, resourceData, "ShadowShaft Blur Horizontal", shadowShaftBlur, shadowShaft, k_BlurHorizontalPass);
                    AddBlurPass(renderGraph, resourceData, "ShadowShaft Blur Vertical", shadowShaft, shadowShaftBlur, k_BlurVerticalPass);
                }

                // ③ カメラカラーに合成して暗くする
                var destDesc = colorDesc;
                destDesc.name = "_CameraColorShadowShaft";
                destDesc.clearBuffer = false;
                TextureHandle destination = renderGraph.CreateTexture(destDesc);

                using (var builder = renderGraph.AddRasterRenderPass<CompositePassData>("ShadowShaft Composite", out var passData, profilingSampler))
                {
                    passData.material = m_Material;
                    passData.source = resourceData.cameraColor;
                    passData.shadowShaft = shadowShaftBlur;

                    builder.UseTexture(resourceData.cameraDepthTexture);
                    builder.UseTexture(passData.source);
                    builder.UseTexture(passData.shadowShaft);
                    builder.SetRenderAttachment(destination, 0, AccessFlags.Write);

                    builder.SetRenderFunc((CompositePassData data, RasterGraphContext context) =>
                    {
                        data.material.SetTexture(s_ShadowShaftBlurTexture, data.shadowShaft);
                        Blitter.BlitTexture(context.cmd, (RTHandle)data.source, new Vector4(1f, 1f, 0f, 0f), data.material, k_CompositePass);
                    });
                }

                resourceData.cameraColor = destination;
            }

            // 入力は Blitter が _BlitTexture としてコマンドに積むので、同じマテリアルで何回呼んでも入力が混ざらない
            void AddBlurPass(RenderGraph renderGraph, UniversalResourceData resourceData, string passName, TextureHandle source, TextureHandle destination, int shaderPass)
            {
                using (var builder = renderGraph.AddRasterRenderPass<BlurPassData>(passName, out var passData, profilingSampler))
                {
                    passData.material = m_Material;
                    passData.source = source;
                    passData.shaderPass = shaderPass;

                    builder.UseTexture(resourceData.cameraDepthTexture);
                    builder.UseTexture(passData.source);
                    builder.SetRenderAttachment(destination, 0, AccessFlags.Write);

                    builder.SetRenderFunc((BlurPassData data, RasterGraphContext context) =>
                    {
                        Blitter.BlitTexture(context.cmd, (RTHandle)data.source, new Vector4(1f, 1f, 0f, 0f), data.material, data.shaderPass);
                    });
                }
            }
        }
    }
}
