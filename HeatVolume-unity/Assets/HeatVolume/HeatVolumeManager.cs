using UnityEngine;
using System.Collections.Generic;

[ExecuteInEditMode]
public class HeatVolumeManager : MonoBehaviour
{
    public enum VolumeShape { Cube, Cylinder }

    [Header("1. 核心资源")]
    public ComputeShader volumeBaker;
    public Material raymarchingMaterial;
    public GameObject sensorPrefab;

    [Header("2. 体积场物理属性")]
    public VolumeShape shapeType = VolumeShape.Cube;
    public Vector3 volumeSize = new Vector3(20, 10, 20);
    public int textureResolution = 64;
    public float sensorRadius = 3.0f;

    [Header("3. 立方体阵列设置 (Cube Only)")]
    public Vector3Int gridCounts = new Vector3Int(5, 3, 5);
    [Range(0f, 1f)]
    public float gridPadding = 0.5f;

    [Header("4. 圆柱体年轮设置 (Cylinder Only)")]
    public int ringCount = 3;           // 几圈
    public int baseSensorsPerRing = 4;  // 最内圈（第一圈）的传感器数量
    public int heightLayers = 5;        // 垂直分几层
    public bool addCenterSensor = true; // 是否在中心轴线放置传感器

    private RenderTexture volumeTexture;
    private List<Transform> activeSensors = new List<Transform>();
    private Vector4[] sensorData = new Vector4[512];
    private GameObject volumeBoundingBox;

    // ========================================================
    // 第一部分：边界框生成 (完全分离)
    // ========================================================

    private void CreateBoundingBox()
    {
        ClearAll();

        PrimitiveType type = (shapeType == VolumeShape.Cube) ? PrimitiveType.Cube : PrimitiveType.Cylinder;
        volumeBoundingBox = GameObject.CreatePrimitive(type);
        volumeBoundingBox.name = $"[V_Box]_{shapeType}";
        volumeBoundingBox.transform.SetParent(this.transform);
        volumeBoundingBox.transform.localPosition = Vector3.zero;
        volumeBoundingBox.transform.localRotation = Quaternion.identity;

        // 统一物理尺寸：Cube默认1x1x1, Cylinder默认半径0.5/高度2
        if (shapeType == VolumeShape.Cylinder)
            volumeBoundingBox.transform.localScale = new Vector3(volumeSize.x, volumeSize.y * 0.5f, volumeSize.z);
        else
            volumeBoundingBox.transform.localScale = volumeSize;

        DestroyImmediate(volumeBoundingBox.GetComponent<Collider>());
        if (raymarchingMaterial != null)
            volumeBoundingBox.GetComponent<MeshRenderer>().sharedMaterial = raymarchingMaterial;
    }

    // ========================================================
    // 第二部分：传感器生成逻辑 (完全分离)
    // ========================================================

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

    [ContextMenu("生成：圆柱体年轮分布 (密度优化版)")]
    public void GenerateCylinderSensors()
    {
        shapeType = VolumeShape.Cylinder;
        CreateBoundingBox();

        float radiusX = volumeSize.x * 0.5f;
        float radiusZ = volumeSize.z * 0.5f;
        float height = volumeSize.y;

        for (int h = 0; h < heightLayers; h++)
        {
            // 计算当前层的高度位置
            float yPos = (heightLayers > 1)
                ? -height * 0.5f + (height / (heightLayers - 1)) * h
                : 0;

            // 1. 中心点传感器
            if (addCenterSensor)
            {
                SpawnSensor(new Vector3(0, yPos, 0), $"S_Cyl_Center_L{h}");
            }

            // 2. 逐圈生成传感器
            for (int r = 1; r <= ringCount; r++)
            {
                float ringProgress = (float)r / ringCount; // 当前半径比例 [0.33, 0.66, 1.0]
                float currRadiusX = radiusX * ringProgress;
                float currRadiusZ = radiusZ * ringProgress;

                // 核心优化：每圈数量 = 基础数量 * 圈数索引
                // 这样外圈的点数会比内圈多，保持空间密度一致
                int currentRingSensorCount = baseSensorsPerRing * r;

                for (int s = 0; s < currentRingSensorCount; s++)
                {
                    float angle = s * (2 * Mathf.PI / currentRingSensorCount);
                    Vector3 pos = new Vector3(
                        Mathf.Cos(angle) * currRadiusX,
                        yPos,
                        Mathf.Sin(angle) * currRadiusZ
                    );
                    SpawnSensor(pos, $"S_Cyl_R{r}_L{h}_{s}");
                }
            }
        }
    }

    private void SpawnSensor(Vector3 localPos, string name)
    {
        if (sensorPrefab == null) return;
        GameObject go = Instantiate(sensorPrefab, transform.TransformPoint(localPos), Quaternion.identity, transform);
        go.name = name;
        activeSensors.Add(go.transform);
    }

    // ========================================================
    // 第三部分：数据更新与计算 (保持通用)
    // ========================================================

    // 必须同步更新 Update 以修复立方体对齐问题
    void Update()
    {
        if (activeSensors.Count == 0 || volumeBaker == null || volumeTexture == null) return;

        int count = Mathf.Min(activeSensors.Count, 512); // 匹配 CS 数组长度
        for (int i = 0; i < count; i++)
        {
            float temp = Mathf.PingPong(Time.time * 20f + (i * 5f), 100f);
            Vector3 p = activeSensors[i].position;
            sensorData[i] = new Vector4(p.x, p.y, p.z, temp);
        }

        // Compute Shader 烘焙
        volumeBaker.SetTexture(0, "VolumeTexture", volumeTexture);
        volumeBaker.SetVectorArray("_SensorPositions", sensorData);
        volumeBaker.SetInt("_SensorCount", count);
        volumeBaker.SetFloat("_Radius", sensorRadius);
        volumeBaker.SetVector("_BoundsMin", transform.position - volumeSize * 0.5f);
        volumeBaker.SetVector("_BoundsSize", volumeSize);
        volumeBaker.SetVector("_TextureSize", Vector3.one * textureResolution);

        int groups = Mathf.CeilToInt(textureResolution / 8f);
        volumeBaker.Dispatch(0, groups, groups, groups);

        // 渲染材质参数更新
        if (raymarchingMaterial != null)
        {
            raymarchingMaterial.SetTexture("_VolumeTexture", volumeTexture);
            raymarchingMaterial.SetMatrix("_WorldToLocal", transform.worldToLocalMatrix);

            // 重要：告知 Shader 当前形状，修复立方体/圆柱体切换时的偏移问题
            raymarchingMaterial.SetFloat("_IsCylinder", shapeType == VolumeShape.Cylinder ? 1.0f : 0.0f);
        }
    }

    public void ClearAll()
    {
        for (int i = transform.childCount - 1; i >= 0; i--) DestroyImmediate(transform.GetChild(i).gameObject);
        activeSensors.Clear();
        volumeBoundingBox = null;
    }

    void OnEnable() { InitRenderTexture(); }
    void InitRenderTexture()
    {
        if (volumeTexture != null) volumeTexture.Release();
        volumeTexture = new RenderTexture(textureResolution, textureResolution, 0, RenderTextureFormat.RGHalf, RenderTextureReadWrite.Linear);
        volumeTexture.dimension = UnityEngine.Rendering.TextureDimension.Tex3D;
        volumeTexture.volumeDepth = textureResolution;
        volumeTexture.enableRandomWrite = true;
        volumeTexture.Create();
    }
}