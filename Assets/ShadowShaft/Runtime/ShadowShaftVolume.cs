using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace ShadowShaft
{
    /// <summary>
    /// レイマーチングを行う解像度。値は画面解像度に対する縮小率の逆数。
    /// </summary>
    public enum ShadowShaftResolution
    {
        Full = 1,
        Half = 2,
        Quarter = 4,
    }

    /// <summary>
    /// ShadowShaft のパラメータ。Volume に追加して使う。
    /// </summary>
    [Serializable]
    [VolumeComponentMenu("Post-processing Custom/Shadow Shaft")]
    [SupportedOnRenderPipeline(typeof(UniversalRenderPipelineAsset))]
    public sealed class ShadowShaftVolume : VolumeComponent
    {
        [Header("Darkening")]
        [Tooltip("全体の効きの強さ。0 で無効。")]
        public ClampedFloatParameter intensity = new ClampedFloatParameter(0f, 0f, 1f);

        [Tooltip("暗くする量の上限。影の区間が長い場所が真っ暗に潰れるのを防ぐ。1 で制限なし。")]
        public ClampedFloatParameter maxDarkness = new ClampedFloatParameter(0.6f, 0f, 1f);

        [Tooltip("影部分に乗算する色。")]
        public ColorParameter shadowColor = new ColorParameter(new Color(0.1f, 0.1f, 0.15f), false, false, true);

        [Header("Stylize")]
        [Tooltip("帯として持ち上げる暗さの中心 (MaxDarkness に対する割合)。Softness 0.5 と合わせて 0.5 なら無変換。")]
        public ClampedFloatParameter threshold = new ClampedFloatParameter(0.5f, 0f, 1f);

        [Tooltip("帯の輪郭のぼかし幅。小さいほどくっきりした影の帯になる。0.5 で無変換。")]
        public ClampedFloatParameter softness = new ClampedFloatParameter(0.5f, 0f, 0.5f);

        [Tooltip("暗さの階調数。0 で階調化なし。")]
        public ClampedIntParameter bands = new ClampedIntParameter(0, 0, 8);

        [Tooltip("MaxDistance の手前から帯を弱めていく範囲 (MaxDistance に対する割合)。0 でフェードなし。")]
        public ClampedFloatParameter distanceFade = new ClampedFloatParameter(0.3f, 0f, 1f);

        [Header("Raymarch")]

        [Tooltip("媒質の密度。大きいほど短い影の区間でも濃くなる。")]
        public MinFloatParameter density = new MinFloatParameter(0.15f, 0f);

        [Tooltip("レイマーチングの最大距離。URP の Shadow Distance を超える分は自動でクランプされる。")]
        public MinFloatParameter maxDistance = new MinFloatParameter(30f, 0.1f);

        [Tooltip("レイマーチングのステップ数。")]
        public ClampedIntParameter stepCount = new ClampedIntParameter(48, 4, 128);

        [Header("Lights")]
        [Tooltip("メインライト (ディレクショナル) の影の寄与。")]
        public MinFloatParameter mainLightWeight = new MinFloatParameter(1f, 0f);

        [Tooltip("スポット / ポイントライトの影の寄与。")]
        public MinFloatParameter additionalLightWeight = new MinFloatParameter(1f, 0f);

        [Tooltip("影を積算するスポット / ポイントライトの上限。カメラに近いものから選ばれる。")]
        public ClampedIntParameter maxAdditionalLights = new ClampedIntParameter(4, 0, ShadowShaftRendererFeature.k_MaxAdditionalLights);

        [Header("Quality")]
        [Tooltip("レイマーチングとブラーを行う解像度。")]
        public EnumParameter<ShadowShaftResolution> resolution = new EnumParameter<ShadowShaftResolution>(ShadowShaftResolution.Half);

        [Tooltip("追加のぼかし回数。帯の縁が柔らかくなり、輪郭付近に残る模様もならされる。0 で追加なし。")]
        public ClampedIntParameter blurIterations = new ClampedIntParameter(0, 0, 4);

        [Tooltip("ブラーと拡大で同じ面とみなす深度差 (中心の深度に対する割合)。小さいほど物体の輪郭で帯がにじみにくいが、傾いた面で模様が残りやすい。")]
        public ClampedFloatParameter depthThreshold = new ClampedFloatParameter(0.1f, 0.01f, 1f);

        public bool IsActive() => intensity.value > 0f && density.value > 0f;
    }
}
