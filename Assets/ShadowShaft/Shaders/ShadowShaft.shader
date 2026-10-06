Shader "Hidden/ShadowShaft"
{
    HLSLINCLUDE
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Shadows.hlsl"
    #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
    #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

    // インターリーブドサンプリングのタイルサイズ (Raymarch のずらし方と Blur の範囲で共有する)
    #define TILE_SIZE 4

    // Blur 系パスの入力は Blitter が _BlitTexture にバインドする (Composite の _BlitTexture はカメラカラー)
    // Composite で読む縮小テクスチャだけ別名で受け取る
    TEXTURE2D_X(_ShadowShaftBlurTexture);
    float4 _ShadowShaftTexelSize; // 縮小テクスチャの (1/幅, 1/高さ, 幅, 高さ)

    float  _Intensity;
    float  _MaxDarkness;
    float4 _ShadowColor;
    float  _Density;
    float  _MaxDistance;
    float  _DistanceFadeStart;
    int    _StepCount;
    float  _Threshold;
    float  _Softness;
    int    _Bands;

    // 中心との深度差がこの割合を超えるピクセルは、ブラーやアップサンプルで別の面として扱う
    float  _DepthThreshold;

    float SampleLinearEyeDepth(float2 uv)
    {
        return LinearEyeDepth(SampleSceneDepth(uv), _ZBufferParams);
    }

    // 同じ面とみなす度合い (0-1)
    // しきい値の半分までは 1 のまま (傾いた面でもブラーの重みが均等になるように)、そこからしきい値で 0 まで下げる
    float DepthWeight(float sampleDepth, float centerDepth)
    {
        float relativeDiff = abs(sampleDepth - centerDepth) / (centerDepth * _DepthThreshold);
        return saturate(2.0 * (1.0 - relativeDiff));
    }

    // 縮小テクスチャ上で 1 方向に 5 タップのガウシアンブラーをかける (深度考慮)
    float GaussianBlur(float2 uv, float2 direction)
    {
        static const float kernel[5] = { 1.0, 4.0, 6.0, 4.0, 1.0 };

        float centerDepth = SampleLinearEyeDepth(uv);
        float sum = 0.0;
        float weightSum = 0.0;

        [unroll]
        for (int i = 0; i < 5; i++)
        {
            float2 sampleUV = uv + direction * (i - 2) * _ShadowShaftTexelSize.xy;
            float weight = kernel[i] * DepthWeight(SampleLinearEyeDepth(sampleUV), centerDepth);

            sum += SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_PointClamp, sampleUV).r * weight;
            weightSum += weight;
        }

        return sum / max(weightSum, 1e-4);
    }
    ENDHLSL

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" }
        ZTest Always
        ZWrite Off
        Cull Off

        // 0: Raymarch
        // レイ上で影に入っている区間の長さを積算し、影の濃さ (0-1) を出力する
        Pass
        {
            Name "ShadowShaft Raymarch"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _ADDITIONAL_LIGHT_SHADOWS

            // C# 側で選んだ追加ライトの上限 (ShadowShaftRendererFeature の k_MaxAdditionalLights と合わせる)
            #define MAX_SHADOW_SHAFT_LIGHTS 8

            float _MainLightWeight;
            float _AdditionalLightWeight;
            int   _ShadowShaftLightCount;
            float _ShadowShaftLightIndices[MAX_SHADOW_SHAFT_LIGHTS]; // URP の追加ライトインデックス (_AdditionalLightsPosition などの添字)

            // メインライトの可視性 (0 = 影, 1 = 日向)
            // TransformWorldToShadowCoord はスクリーンスペースシャドウ時に別の処理になるため、シャドウマップを直接引く
            float SampleMainLightVisibility(float3 positionWS)
            {
            #if defined(_MAIN_LIGHT_SHADOWS) || defined(_MAIN_LIGHT_SHADOWS_CASCADE)
                #if defined(_MAIN_LIGHT_SHADOWS_CASCADE)
                    half cascadeIndex = ComputeCascadeIndex(positionWS);
                #else
                    half cascadeIndex = half(0.0);
                #endif

                float4 shadowCoord = float4(mul(_MainLightWorldToShadow[cascadeIndex], float4(positionWS, 1.0)).xyz, 0.0);
                float attenuation = SAMPLE_TEXTURE2D_SHADOW(_MainLightShadowmapTexture, sampler_LinearClampCompare, shadowCoord.xyz);
                attenuation = LerpWhiteTo(attenuation, _MainLightShadowParams.x);
                return BEYOND_SHADOW_FAR(shadowCoord) ? 1.0 : attenuation;
            #else
                return 1.0;
            #endif
            }

            // 追加ライト (スポット / ポイント) の可視性 (0 = 影, 1 = 日向)
            // ソフトシャドウのキーワードに左右されないよう、シャドウアトラスを 1 回だけ比較サンプルする
            float SampleAdditionalLightVisibility(int lightIndex, float3 positionWS, float3 lightPositionWS)
            {
            #if defined(ADDITIONAL_LIGHT_CALCULATE_SHADOWS)
                half4 shadowParams = GetAdditionalLightShadowParams(lightIndex);
                int shadowSliceIndex = shadowParams.w;
                if (shadowSliceIndex < 0)
                    return 1.0;

                // ポイントライトはライトから見た方向でキューブの面 (スライス) を選ぶ
                if (shadowParams.z > 0.5)
                    shadowSliceIndex += CubeMapFaceID(positionWS - lightPositionWS);

                float4 shadowCoord = mul(_AdditionalLightsWorldToShadow[shadowSliceIndex], float4(positionWS, 1.0));
                shadowCoord.xyz /= shadowCoord.w;
                float attenuation = SAMPLE_TEXTURE2D_SHADOW(_AdditionalLightsShadowmapTexture, sampler_LinearClampCompare, shadowCoord.xyz);
                attenuation = LerpWhiteTo(attenuation, shadowParams.x);
                return BEYOND_SHADOW_FAR(shadowCoord) ? 1.0 : attenuation;
            #else
                return 1.0;
            #endif
            }

            // 追加ライトがその点に届いている度合い (0-1)
            // URP と同じ範囲端のスムーズな減衰とスポットのコーン減衰を使う。距離の 2 乗減衰は使わない (スタイライズのため)
            float AdditionalLightReach(int lightIndex, float3 positionWS)
            {
                float3 toLight = _AdditionalLightsPosition[lightIndex].xyz - positionWS;
                float distanceSqr = max(dot(toLight, toLight), 1e-4);
                half4 attenuation = _AdditionalLightsAttenuation[lightIndex];

                float factor = distanceSqr * attenuation.x;
                float rangeFade = saturate(1.0 - factor * factor);
                rangeFade *= rangeFade;

                // ポイントライトは attenuation.zw = (0, 1) なのでコーン減衰は常に 1
                float3 lightDirection = toLight * rsqrt(distanceSqr);
                float spotFade = saturate(dot(_AdditionalLightsSpotDir[lightIndex].xyz, lightDirection) * attenuation.z + attenuation.w);
                spotFade *= spotFade;

                return rangeFade * spotFade;
            }

            // その点が影になっている度合い。lightIndex < 0 はメインライトを表す
            float ShadowAmount(int lightIndex, float3 positionWS)
            {
                if (lightIndex < 0)
                    return 1.0 - SampleMainLightVisibility(positionWS);

                // ライトが届かない場所は影ではなく暗がりなので帯にしない (シャドウアトラスの範囲外も読まない)
                float reach = AdditionalLightReach(lightIndex, positionWS);
                if (reach <= 0.0)
                    return 0.0;

                return reach * (1.0 - SampleAdditionalLightVisibility(lightIndex, positionWS, _AdditionalLightsPosition[lightIndex].xyz));
            }

            // カメラからの距離による寄与の減衰 (1 → 0)
            // MaxDistance や Shadow Distance で帯が急に途切れないよう、_DistanceFadeStart から MaxDistance にかけて弱める
            float DistanceFade(float t)
            {
                return saturate((_MaxDistance - t) / max(_MaxDistance - _DistanceFadeStart, 1e-4));
            }

            // レイ上の区間 [tBegin, tEnd] で影に入っている長さを積算する
            // 区間の境界は全ライト共通のグリッド (k + offset) * dt に揃え、Blur でのずらしの打ち消しが効くようにする
            float MarchShadowLength(int lightIndex, float3 startWS, float3 rayDir, float tBegin, float tEnd, float dt, float offset, int stepCount)
            {
                float shadowLength = 0.0;
                int firstSegment = (int)floor(tBegin / dt - offset) + 1;

                [loop]
                for (int i = 0; i <= stepCount; i++)
                {
                    // 区間 [(k-1+offset)*dt, (k+offset)*dt] を [tBegin, tEnd] で切り取り、中点で代表させる
                    int k = firstSegment + i;
                    float segmentStart = max((k - 1 + offset) * dt, tBegin);
                    if (segmentStart >= tEnd)
                        break;

                    float segmentEnd = min((k + offset) * dt, tEnd);
                    float segmentLength = segmentEnd - segmentStart;
                    if (segmentLength <= 0.0)
                        continue;

                    float t = segmentStart + segmentLength * 0.5;
                    float3 positionWS = startWS + rayDir * t;
                    shadowLength += ShadowAmount(lightIndex, positionWS) * DistanceFade(t) * segmentLength;
                }

                return shadowLength;
            }

            // 4x4 Bayer 行列による 0-1 のオフセット (タイル内で 16 通りが 1 回ずつ現れる)
            float BayerOffset(uint2 pixel)
            {
                static const float bayer[16] =
                {
                     0.0,  8.0,  2.0, 10.0,
                    12.0,  4.0, 14.0,  6.0,
                     3.0, 11.0,  1.0,  9.0,
                    15.0,  7.0, 13.0,  5.0
                };
                uint2 p = pixel % TILE_SIZE;
                return bayer[p.y * TILE_SIZE + p.x] / (TILE_SIZE * TILE_SIZE);
            }

            float Frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                float2 uv = input.texcoord;

                float rawDepth = SampleSceneDepth(uv);
            #if !UNITY_REVERSED_Z
                rawDepth = lerp(UNITY_NEAR_CLIP_VALUE, 1.0, rawDepth);
            #endif
                bool isSky = rawDepth == UNITY_RAW_FAR_CLIP_VALUE;

                // ニアプレーン上の点から開始する (平行投影でも成立する)
                float3 startWS = ComputeWorldSpacePosition(uv, UNITY_NEAR_CLIP_VALUE, UNITY_MATRIX_I_VP);
                float3 endWS = ComputeWorldSpacePosition(uv, rawDepth, UNITY_MATRIX_I_VP);

                float3 ray = endWS - startWS;
                float rayLength = length(ray);
                float3 rayDir = ray / max(rayLength, 1e-5);
                float tMax = isSky ? _MaxDistance : min(rayLength, _MaxDistance);

                // 刻み幅はワールド空間で一定にする
                // (レイ長で割ると、平面上のピクセルでサンプル点が同じ高さの板に揃って縞になる)
                int stepCount = max(_StepCount, 1);
                float dt = _MaxDistance / stepCount;

                // 4x4 タイル内の各ピクセルで区間の境界を 0/16 - 15/16 ステップずらす
                // Blur でタイル分を平均すると、16 倍のステップ数で積分したのと同等になる
                float offset = BayerOffset(uint2(input.positionCS.xy));

                float shadowLength = 0.0;

                if (_MainLightWeight > 0.0)
                    shadowLength += _MainLightWeight * MarchShadowLength(-1, startWS, rayDir, 0.0, tMax, dt, offset, stepCount);

            #if defined(ADDITIONAL_LIGHT_CALCULATE_SHADOWS)
                int lightCount = min(_ShadowShaftLightCount, MAX_SHADOW_SHAFT_LIGHTS);

                [loop]
                for (int i = 0; i < lightCount; i++)
                {
                    int lightIndex = (int)_ShadowShaftLightIndices[i];

                    // ライトの範囲 (球) とレイが交わる区間だけをマーチする
                    float3 lightPositionWS = _AdditionalLightsPosition[lightIndex].xyz;
                    float rangeSqr = rcp(max(_AdditionalLightsAttenuation[lightIndex].x, 1e-6));
                    float3 fromLight = startWS - lightPositionWS;
                    float b = dot(fromLight, rayDir);
                    float h = b * b - (dot(fromLight, fromLight) - rangeSqr);
                    if (h <= 0.0)
                        continue;

                    h = sqrt(h);
                    float tBegin = max(-b - h, 0.0);
                    float tEnd = min(-b + h, tMax);
                    if (tBegin >= tEnd)
                        continue;

                    // ライトの色の明るさを重みにする (明るさ 1 以上は同じ扱い)
                    float lightWeight = _AdditionalLightWeight * saturate(Luminance(_AdditionalLightsColor[lightIndex].rgb));
                    shadowLength += lightWeight * MarchShadowLength(lightIndex, startWS, rayDir, tBegin, tEnd, dt, offset, stepCount);
                }
            #endif

                return 1.0 - exp(-_Density * shadowLength);
            }
            ENDHLSL
        }

        // 1: Blur
        // 4x4 タイル分を平均してインターリーブドサンプリングのずらしを打ち消す
        // 深度差の大きいピクセルは除外し、物体の輪郭で影の筋がにじまないようにする
        Pass
        {
            Name "ShadowShaft Blur"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            float Frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                float2 uv = input.texcoord;

                float centerDepth = SampleLinearEyeDepth(uv);
                float sum = 0.0;
                float weightSum = 0.0;

                // 連続する 4x4 ピクセル (-2 .. +1) には Bayer の 16 通りのずらしがちょうど 1 回ずつ含まれる
                [unroll]
                for (int y = -TILE_SIZE / 2; y < TILE_SIZE / 2; y++)
                {
                    [unroll]
                    for (int x = -TILE_SIZE / 2; x < TILE_SIZE / 2; x++)
                    {
                        float2 sampleUV = uv + float2(x, y) * _ShadowShaftTexelSize.xy;
                        float weight = DepthWeight(SampleLinearEyeDepth(sampleUV), centerDepth);

                        sum += SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_PointClamp, sampleUV).r * weight;
                        weightSum += weight;
                    }
                }

                return sum / max(weightSum, 1e-4);
            }
            ENDHLSL
        }

        // 2: Composite
        // 縮小テクスチャを深度考慮で拡大し、影の濃さに応じてカメラカラーに ShadowColor を乗算する (暗くするだけ)
        Pass
        {
            Name "ShadowShaft Composite"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            // 周囲 2x2 の縮小テクセルをバイリニアの重みで補間する。ただし深度が中心と大きく違うテクセルは除外する
            // (Full 解像度のときはテクセル中心に一致するので、そのままの値になる)
            float SampleDarknessUpsampled(float2 uv)
            {
                float centerDepth = SampleLinearEyeDepth(uv);

                float2 position = uv * _ShadowShaftTexelSize.zw - 0.5;
                float2 baseTexel = floor(position);
                float2 fraction = position - baseTexel;

                float sum = 0.0;
                float weightSum = 0.0;
                float nearestValue = 0.0;
                float nearestDepthDiff = FLT_MAX;

                [unroll]
                for (int i = 0; i < 4; i++)
                {
                    float2 offset = float2(i & 1, i >> 1);
                    float2 texelUV = (baseTexel + offset + 0.5) * _ShadowShaftTexelSize.xy;

                    // Raymarch / Blur と同じ位置の深度を引くことで、そのテクセルが表す面と比較する
                    float texelDepth = SampleLinearEyeDepth(texelUV);
                    float depthDiff = abs(texelDepth - centerDepth);
                    float value = SAMPLE_TEXTURE2D_X(_ShadowShaftBlurTexture, sampler_PointClamp, texelUV).r;

                    float2 bilinear = lerp(1.0 - fraction, fraction, offset);
                    float weight = bilinear.x * bilinear.y * DepthWeight(texelDepth, centerDepth);
                    sum += value * weight;
                    weightSum += weight;

                    if (depthDiff < nearestDepthDiff)
                    {
                        nearestDepthDiff = depthDiff;
                        nearestValue = value;
                    }
                }

                // 同じ面のテクセルが見つからない場合は、深度が最も近いテクセルを使う
                return weightSum > 1e-4 ? sum / weightSum : nearestValue;
            }

            // 暗さ (0-1、1 = MaxDarkness) をスタイライズする
            // Threshold を中心に幅 Softness * 2 で 0 → 1 に持ち上げ、帯の輪郭をくっきりさせる (0.5 / 0.5 で無変換)
            // Bands > 0 なら段階的な濃さに丸める
            float Stylize(float x)
            {
                // ランプ幅は最低でも約 1 ピクセルにして、Softness 0 でも輪郭がジャギにならないようにする
                // 両端は 0-1 に収め、影のない場所 (0) が暗くなったり最大の暗さ (1) に届かなくなったりしないようにする
                float halfWidth = max(_Softness, fwidth(x) * 0.5);
                float lower = saturate(_Threshold - halfWidth);
                float upper = saturate(_Threshold + halfWidth);
                x = saturate((x - lower) / max(upper - lower, 1e-4));

                if (_Bands > 0)
                    x = floor(x * _Bands + 0.5) / _Bands;

                return x;
            }

            half4 Frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                float2 uv = input.texcoord;

                half4 color = SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_PointClamp, uv);
                half darkness = SampleDarknessUpsampled(uv);

                // 影の区間が長い場所でも MaxDarkness 以上は暗くしない
                float amount = min(saturate(darkness * _Intensity), _MaxDarkness);
                amount = Stylize(amount / max(_MaxDarkness, 1e-4)) * _MaxDarkness;

                color.rgb = lerp(color.rgb, color.rgb * _ShadowColor.rgb, amount);
                return color;
            }
            ENDHLSL
        }

        // 3: Blur Horizontal
        // 追加のぼかし (BlurIterations > 0 のとき)。帯の縁を柔らかくし、輪郭付近に残ったずらしの模様もならす
        Pass
        {
            Name "ShadowShaft Blur Horizontal"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            float Frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                return GaussianBlur(input.texcoord, float2(1.0, 0.0));
            }
            ENDHLSL
        }

        // 4: Blur Vertical
        Pass
        {
            Name "ShadowShaft Blur Vertical"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            float Frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);
                return GaussianBlur(input.texcoord, float2(0.0, 1.0));
            }
            ENDHLSL
        }
    }
}
