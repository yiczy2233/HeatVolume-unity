using UnityEngine;
using System.Collections.Generic;
using UnityEngine.InputSystem;

[ExecuteInEditMode]
public class HeatVolumeManager_GPU : MonoBehaviour
{
    public enum VolumeShape { Cube, Cylinder }
    // Manual 模式下，Update 只负责同步数据，不主动修改 SensorNode 的值
    private enum TempMode { Manual }

    [Header("1. 核心资源")]
    public ComputeShader volumeBaker;
    public Material raymarchingMaterial;
    public GameObject sensorPrefab;
    public GameObject[] ringVisualPrefabs;
    public GameObject pillarPrefab;

    [Header("2. 体积场物理属性")]
    public VolumeShape shapeType = VolumeShape.Cube;
    public Vector3 volumeSize = new Vector3(20, 10, 20);
    public int textureResolution = 64;
    public float sensorRadius = 3.0f;

    [Header("3. 分层模式设置 (Q键)")]
    public float topTemp = 85f;
    public float middleTemp = 30f;
    public float bottomTemp = 12f;

    [Header("4. 动态快照调节 (W键)")]
    public float horizontalSpread = 0.5f;
    public float verticalConsistency = 0.05f;

    [Header("5. 阵列设置")]
    public Vector3Int gridCounts = new Vector3Int(5, 3, 5);
    [Range(0f, 1f)] public float gridPadding = 0.5f;
    public List<int> ringSettings = new List<int> { 4, 8, 12 };
    public int heightLayers = 5;
    public bool addCenterSensor = true;
    [Range(0f, 1f)] public float cylinderPadding = 0.15f;

    private RenderTexture volumeTexture;
    private List<SensorNode> activeSensors = new List<SensorNode>();
    private Vector4[] sensorData = new Vector4[1024];
    private GameObject volumeBoundingBox;

    // ========================================================
    // 第一部分：温度生成方法 (触发式调用)
    // ========================================================

    [ContextMenu("Q: 应用分层温度")]
    public void ApplyLayeredTemperature()
    {
        if (activeSensors.Count == 0) return;
        float halfHeight = volumeSize.y * 0.5f;

        foreach (var sensor in activeSensors)
        {
            if (sensor == null) continue;
            // 计算高度占比
            float normalizedY = (sensor.transform.localPosition.y + halfHeight) / volumeSize.y;
            float finalTemp = (normalizedY > 0.7f) ? topTemp : (normalizedY < 0.3f ? bottomTemp : middleTemp);

            // 调用 SensorNode 的方法，会同步更新 currentTemp 和视觉颜色
            sensor.UpdateTemperature(finalTemp);
        }
        Debug.Log("温度初始化：分层模式 (Q) 已应用");
    }

    [ContextMenu("W: 应用动态快照温度")]
    public void ApplyDynamicTemperature()
    {
        if (activeSensors.Count == 0) return;
        for (int i = 0; i < activeSensors.Count; i++)
        {
            if (activeSensors[i] == null) continue;
            Vector3 lp = activeSensors[i].transform.localPosition;
            float columnPhase = (lp.x + lp.z) * horizontalSpread;
            float heightEffect = lp.y * verticalConsistency;
            // 采样当前时刻的 PingPong 值作为固定值
            float t = Mathf.PingPong(Time.time + columnPhase + heightEffect, 1.0f);
            activeSensors[i].UpdateTemperature(Mathf.Lerp(0f, 100f, t));
        }
        Debug.Log("温度初始化：动态快照 (W) 已应用");
    }

    [ContextMenu("E: 应用随机稀疏温度")]
    public void ApplySparseTemperature()
    {
        if (activeSensors.Count == 0) return;
        for (int i = 0; i < activeSensors.Count; i++)
        {
            if (activeSensors[i] == null) continue;
            Random.InitState(i + (int)(Time.time * 100));
            float chance = Random.value;
            float finalTemp = (chance > 0.95f) ? Random.Range(85f, 100f) : (chance < 0.05f ? Random.Range(0f, 15f) : Random.Range(25f, 35f));
            activeSensors[i].UpdateTemperature(finalTemp);
        }
        Debug.Log("温度初始化：随机稀疏 (E) 已应用");
    }

    // ========================================================
    // 第二部分：数据同步与渲染
    // ========================================================

    void Update()
    {
        if (volumeBaker == null || volumeTexture == null) return;

        // 检测按键
        HandleInput();

        if (activeSensors.Count == 0) return;

        // 核心逻辑：每一帧只做“搬运工”
        // 将 SensorNode.currentTemp 里的值传给 Compute Shader
        int count = Mathf.Min(activeSensors.Count, 1024);
        for (int i = 0; i < count; i++)
        {
            var sensor = activeSensors[i];
            if (sensor == null) continue;

            Vector3 worldP = sensor.transform.position;
            // 修正变量名为 currentTemp
            sensorData[i] = new Vector4(worldP.x, worldP.y, worldP.z, sensor.currentTemp);
        }

        DispatchCompute(count);
    }

    private void HandleInput()
    {
        var keyboard = Keyboard.current;
        if (keyboard == null) return;

        if (keyboard.qKey.wasPressedThisFrame) ApplyLayeredTemperature();
        if (keyboard.wKey.wasPressedThisFrame) ApplyDynamicTemperature();
        if (keyboard.eKey.wasPressedThisFrame) ApplySparseTemperature();

        if (keyboard.aKey.wasPressedThisFrame) GenerateCylinderSensors();
        if (keyboard.sKey.wasPressedThisFrame) GenerateCubeSensors();
    }

    private void DispatchCompute(int count)
    {
        volumeBaker.SetTexture(0, "VolumeTexture", volumeTexture);
        volumeBaker.SetVectorArray("_SensorPositions", sensorData);
        volumeBaker.SetInt("_SensorCount", count);
        volumeBaker.SetFloat("_Radius", sensorRadius);
        volumeBaker.SetVector("_BoundsMin", transform.position - volumeSize * 0.5f);
        volumeBaker.SetVector("_BoundsSize", volumeSize);
        volumeBaker.SetVector("_TextureSize", Vector3.one * textureResolution);

        int groups = Mathf.CeilToInt(textureResolution / 8f);
        volumeBaker.Dispatch(0, groups, groups, groups);

        if (raymarchingMaterial != null)
        {
            raymarchingMaterial.SetTexture("_VolumeTexture", volumeTexture);
            raymarchingMaterial.SetMatrix("_WorldToLocal", transform.worldToLocalMatrix);
            raymarchingMaterial.SetFloat("_IsCylinder", shapeType == VolumeShape.Cylinder ? 1.0f : 0.0f);
        }
    }

    // ========================================================
    // 第三部分：生成与清理 (逻辑保持不变)
    // ========================================================

    public void ClearAll()
    {
        for (int i = transform.childCount - 1; i >= 0; i--) DestroyImmediate(transform.GetChild(i).gameObject);
        activeSensors.Clear();
        volumeBoundingBox = null;
    }

    [ContextMenu("生成：立方体分布")]
    public void GenerateCubeSensors()
    {
        shapeType = VolumeShape.Cube;
        CreateBoundingBox();
        Vector3 spacing = Vector3.zero;
        Vector3 startOffset = -volumeSize / 2f;
        spacing.x = gridCounts.x > 1 ? volumeSize.x / (gridCounts.x - 1 + (gridPadding * 2f)) : 0;
        spacing.y = gridCounts.y > 1 ? volumeSize.y / (gridCounts.y - 1 + (gridPadding * 2f)) : 0;
        spacing.z = gridCounts.z > 1 ? volumeSize.z / (gridCounts.z - 1 + (gridPadding * 2f)) : 0;
        startOffset.x += (gridCounts.x > 1) ? spacing.x * gridPadding : volumeSize.x * 0.5f + startOffset.x;
        startOffset.y += (gridCounts.y > 1) ? spacing.y * gridPadding : volumeSize.y * 0.5f + startOffset.y;
        startOffset.z += (gridCounts.z > 1) ? spacing.z * gridPadding : volumeSize.z * 0.5f + startOffset.z;

        for (int y = 0; y < gridCounts.y; y++)
            for (int z = 0; z < gridCounts.z; z++)
                for (int x = 0; x < gridCounts.x; x++)
                    SpawnSensor(startOffset + new Vector3(x * spacing.x, y * spacing.y, z * spacing.z), $"S_Cube_{x}_{y}_{z}");
    }

    [ContextMenu("生成：圆柱体分布")]
    public void GenerateCylinderSensors()
    {
        shapeType = VolumeShape.Cylinder;
        CreateBoundingBox();
        if (ringSettings == null || ringSettings.Count == 0) return;
        float maxRadiusX = (volumeSize.x * 0.5f) * (1f - cylinderPadding);
        float maxRadiusZ = (volumeSize.z * 0.5f) * (1f - cylinderPadding);
        float maxHeight = volumeSize.y * (1f - cylinderPadding);

        for (int h = 0; h < heightLayers; h++)
        {
            float yPos = (heightLayers > 1) ? -maxHeight * 0.5f + (maxHeight / (heightLayers - 1)) * h : 0;
            if (addCenterSensor) SpawnSensor(new Vector3(0, yPos, 0), $"S_Cyl_Center_L{h}");
            for (int r = 0; r < ringSettings.Count; r++)
            {
                float ringProgress = (float)(r + 1) / ringSettings.Count;
                int sc = Mathf.Max(1, ringSettings[r]);
                for (int s = 0; s < sc; s++)
                {
                    float angle = s * (2 * Mathf.PI / sc);
                    Vector3 pos = new Vector3(Mathf.Cos(angle) * maxRadiusX * ringProgress, yPos, Mathf.Sin(angle) * maxRadiusZ * ringProgress);
                    SpawnSensor(pos, $"S_Cyl_R{r}_L{h}_{s}");
                }
            }
        }
    }

    private void CreateBoundingBox()
    {
        ClearAll();
        PrimitiveType type = (shapeType == VolumeShape.Cube) ? PrimitiveType.Cube : PrimitiveType.Cylinder;
        volumeBoundingBox = GameObject.CreatePrimitive(type);
        volumeBoundingBox.transform.SetParent(this.transform);
        volumeBoundingBox.transform.localPosition = Vector3.zero;
        volumeBoundingBox.transform.localScale = (shapeType == VolumeShape.Cylinder) ? new Vector3(volumeSize.x, volumeSize.y * 0.5f, volumeSize.z) : volumeSize;
        DestroyImmediate(volumeBoundingBox.GetComponent<Collider>());
        if (raymarchingMaterial != null) volumeBoundingBox.GetComponent<MeshRenderer>().sharedMaterial = raymarchingMaterial;
    }

    private void SpawnSensor(Vector3 localPos, string name)
    {
        if (sensorPrefab == null) return;
        Vector3 dir = new Vector3(0, localPos.y, 0) - localPos;
        Quaternion rot = (dir != Vector3.zero) ? Quaternion.LookRotation(transform.TransformDirection(dir)) : Quaternion.identity;
        GameObject go = Instantiate(sensorPrefab, transform.TransformPoint(localPos), rot, transform);
        go.name = name;
        SensorNode node = go.GetComponent<SensorNode>() ?? go.AddComponent<SensorNode>();
        activeSensors.Add(node);
    }

    void OnEnable() { InitRenderTexture(); }
    void InitRenderTexture()
    {
        if (volumeTexture != null) volumeTexture.Release();
        volumeTexture = new RenderTexture(textureResolution, textureResolution, 0, RenderTextureFormat.RGHalf, RenderTextureReadWrite.Linear)
        {
            dimension = UnityEngine.Rendering.TextureDimension.Tex3D,
            volumeDepth = textureResolution,
            enableRandomWrite = true
        };
        volumeTexture.Create();
    }
}