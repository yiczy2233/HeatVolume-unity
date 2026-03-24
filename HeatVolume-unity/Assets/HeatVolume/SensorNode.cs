using UnityEngine;

[RequireComponent(typeof(MeshRenderer))]
public class SensorNode : MonoBehaviour
{
    [Header("温度数据")]
    public float currentTemp = 25f;

    [Header("视觉颜色 (支持 HDR)")]
    [ColorUsage(true, true)] public Color coldColor = Color.blue;
    [ColorUsage(true, true)] public Color normalColor = Color.green;
    [ColorUsage(true, true)] public Color hotColor = Color.red;

    private MeshRenderer _renderer;
    private MaterialPropertyBlock _mpb;

    // 缓存 Shader 属性 ID
    private static readonly int BaseColorId = Shader.PropertyToID("_BaseColor");
    private static readonly int EmissionColorId = Shader.PropertyToID("_EmissionColor");

    /// <summary>
    /// 由 HeatVolumeManager 的 Update 统一调用
    /// </summary>
    public void UpdateTemperature(float temp)
    {
        currentTemp = temp;

        // 1. 懒加载：确保 _renderer 和 _mpb 始终有效
        if (_renderer == null) _renderer = GetComponent<MeshRenderer>();
        if (_mpb == null) _mpb = new MaterialPropertyBlock();

        Color targetColor = normalColor;

        // 2. 三态逻辑
        if (temp <= 20f) targetColor = coldColor;
        else if (temp >= 60f) targetColor = hotColor;
        else targetColor = normalColor;

        // 3. 应用颜色到 MPB
        if (_renderer != null)
        {
            // 先获取当前的属性块（防止覆盖其他属性）
            _renderer.GetPropertyBlock(_mpb);

            // 设置颜色
            _mpb.SetColor(BaseColorId, targetColor);
            _mpb.SetColor(EmissionColorId, targetColor * 1.5f);

            // 重新设回给 Renderer
            _renderer.SetPropertyBlock(_mpb);
        }
    }

    // 删除了原来的 Awake 逻辑，因为 UpdateTemperature 现在自带初始化功能
}