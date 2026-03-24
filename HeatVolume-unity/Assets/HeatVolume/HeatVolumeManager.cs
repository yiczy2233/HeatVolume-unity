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
    // 新增：线圈预制体数组，建议按 [内圈, 中圈, 外圈] 顺序拖入
    public GameObject[] ringVisualPrefabs;
    public GameObject pillarPrefab; // 新增：垂直杆子预制体

    [Header("2. 体积场物理属性")]
    public VolumeShape shapeType = VolumeShape.Cube;
    public Vector3 volumeSize = new Vector3(20, 10, 20);
    public int textureResolution = 64;
    public float sensorRadius = 3.0f;

    [Header("3. 立方体阵列设置 (Cube Only)")]
    public Vector3Int gridCounts = new Vector3Int(5, 3, 5);
    [Range(0f, 1f)]
    public float gridPadding = 0.5f;

    [Tooltip("列表长度决定圈数，每个数值决定该圈的传感器数量")]
    public List<int> ringSettings = new List<int> { 4, 8, 12 };
    public int heightLayers = 5;
    public bool addCenterSensor = true;
    [Range(0f, 1f)]
    public float cylinderPadding = 0.15f;

    private RenderTexture volumeTexture;

    // 关键修改：直接存储 SensorNode 组件列表
    private List<SensorNode> activeSensors = new List<SensorNode>();
    private Vector4[] sensorData = new Vector4[1024];
    private GameObject volumeBoundingBox;

    // ========================================================
    // 第一部分：边界框生成
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

        if (shapeType == VolumeShape.Cylinder)
            volumeBoundingBox.transform.localScale = new Vector3(volumeSize.x, volumeSize.y * 0.5f, volumeSize.z);
        else
            volumeBoundingBox.transform.localScale = volumeSize;

        DestroyImmediate(volumeBoundingBox.GetComponent<Collider>());
        if (raymarchingMaterial != null)
            volumeBoundingBox.GetComponent<MeshRenderer>().sharedMaterial = raymarchingMaterial;
    }

    // ========================================================
    // 第二部分：传感器生成逻辑
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

    [ContextMenu("生成：圆柱体年轮分布 (自定义列数)")]
    public void GenerateCylinderSensors()
    {
        shapeType = VolumeShape.Cylinder;
        CreateBoundingBox();

        if (ringSettings == null || ringSettings.Count == 0) return;

        float maxRadiusX = (volumeSize.x * 0.5f) * (1f - cylinderPadding);
        float maxRadiusZ = (volumeSize.z * 0.5f) * (1f - cylinderPadding);
        float maxHeight = volumeSize.y * (1f - cylinderPadding);

        int actualRingCount = ringSettings.Count;



        // --- 新增：先生成垂直杆子 ---
        for (int r = 0; r < actualRingCount; r++)
        {
            float ringProgress = (float)(r + 1) / actualRingCount;
            float currRadiusX = maxRadiusX * ringProgress;
            float currRadiusZ = maxRadiusZ * ringProgress;
            int currentRingSensorCount = Mathf.Max(1, ringSettings[r]);

            for (int s = 0; s < currentRingSensorCount; s++)
            {
                float angle = s * (2 * Mathf.PI / currentRingSensorCount);
                Vector3 pillarPos = new Vector3(Mathf.Cos(angle) * currRadiusX, 0, Mathf.Sin(angle) * currRadiusZ);

                if (pillarPrefab != null)
                {
                    // 生成杆子并挂载
                    GameObject pillar = Instantiate(pillarPrefab, transform.TransformPoint(pillarPos), Quaternion.identity, transform);
                    pillar.name = $"Pillar_R{r}_S{s}";
                    // 自动拉伸杆子高度以匹配体积
                   // pillar.transform.localScale = new Vector3(pillar.transform.localScale.x, maxHeight, pillar.transform.localScale.z);
                }
            }

            // 如果有中心传感器，也给中心加一根杆子
            if (addCenterSensor && r == 0)
            {
                GameObject centerPillar = Instantiate(pillarPrefab, transform.TransformPoint(Vector3.zero), Quaternion.identity, transform);
                centerPillar.name = "Pillar_Center";
               // centerPillar.transform.localScale = new Vector3(centerPillar.transform.localScale.x, maxHeight, centerPillar.transform.localScale.z);
            }
        }




        for (int h = 0; h < heightLayers; h++)
        {
            float yPos = (heightLayers > 1)
                ? -maxHeight * 0.5f + (maxHeight / (heightLayers - 1)) * h
                : 0;

            // 1. 中心轴线传感器
            if (addCenterSensor)
            {
                SpawnSensor(new Vector3(0, yPos, 0), $"S_Cyl_Center_L{h}");
            }

            // 2. 遍历每一圈
            for (int r = 0; r < actualRingCount; r++)
            {
                // --- 核心修改：仅生成并定位，不改动 Scale ---
                if (ringVisualPrefabs != null && r < ringVisualPrefabs.Length && ringVisualPrefabs[r] != null)
                {
                    GameObject ringObj = Instantiate(ringVisualPrefabs[r], transform);
                    ringObj.name = $"Ring_Vfx_R{r}_L{h}";

                    // 仅同步本地坐标，保持预制体原始的 Scale 和 Rotation
                    ringObj.transform.localPosition = new Vector3(0, yPos, 0);
                }
                // ------------------------------------------

                float ringProgress = (float)(r + 1) / actualRingCount;
                float currRadiusX = maxRadiusX * ringProgress;
                float currRadiusZ = maxRadiusZ * ringProgress;

                int currentRingSensorCount = Mathf.Max(1, ringSettings[r]);
                for (int s = 0; s < currentRingSensorCount; s++)
                {
                    // ... 生成传感器的逻辑保持不变 ...
                    float angle = s * (2 * Mathf.PI / currentRingSensorCount);
                    Vector3 pos = new Vector3(Mathf.Cos(angle) * currRadiusX, yPos, Mathf.Sin(angle) * currRadiusZ);
                    SpawnSensor(pos, $"S_Cyl_R{r}_L{h}_{s}");
                }
            }
        }
    }

    private void SpawnSensor(Vector3 localPos, string name)
    {
        if (sensorPrefab == null) return;

        // 1. 计算朝向：从当前点指向中心轴 (0, localPos.y, 0)
        // 注意：如果想让传感器背对中心，只需反转向量：localPos - new Vector3(0, localPos.y, 0)
        Vector3 directionToCenter = new Vector3(0, localPos.y, 0) - localPos;

        // 2. 处理中心点情况：如果就在中心点，则保持默认旋转
        Quaternion rotation = (directionToCenter != Vector3.zero)
            ? Quaternion.LookRotation(transform.TransformDirection(directionToCenter))
            : Quaternion.identity;

        // 3. 实例化并设置旋转
        GameObject go = Instantiate(sensorPrefab, transform.TransformPoint(localPos), rotation, transform);
        go.name = name;

        // 获取并存储脚本组件
        SensorNode node = go.GetComponent<SensorNode>();
        if (node == null) node = go.AddComponent<SensorNode>();
        activeSensors.Add(node);
    }

    // ========================================================
    // 第三部分：数据更新与计算
    // ========================================================
    void Update()
    {
        if (activeSensors.Count == 0 || volumeBaker == null || volumeTexture == null) return;

        int count = Mathf.Min(activeSensors.Count, 1024);

        // 设置基础温区（例如：25.0°C - 35.0°C 之间的小幅波动）
        float baseTempMin = 25f;
        float baseTempMax = 35f;

        for (int i = 0; i < count; i++)
        {
            if (activeSensors[i] != null)
            {
                float finalTemp;

                // 使用伪随机种子，保证每个点有固定的“性格”
                Random.InitState(i);
                float chance = Random.value;

                if (chance > 0.97f)
                {
                    // 3% 的概率出现极端高温 (例如 80°C - 100°C)
                    finalTemp = Random.Range(80f, 100f);
                }
                else if (chance < 0.03f)
                {
                    // 3% 的概率出现异常低温 (例如 0°C - 10°C)
                    finalTemp = Random.Range(0f, 10f);
                }
                else
                {
                    // 剩余 94% 的点处于正常环境温度，带一点点随机扰动
                    finalTemp = Random.Range(baseTempMin, baseTempMax);
                }

                // 更新传感器表现和数据
                activeSensors[i].UpdateTemperature(finalTemp);
                Vector3 p = activeSensors[i].transform.position;
                sensorData[i] = new Vector4(p.x, p.y, p.z, finalTemp);
            }
        }

        // --- 以下 Compute Shader 提交逻辑保持不变 ---
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

    public void ClearAll()
    {
        for (int i = transform.childCount - 1; i >= 0; i--) DestroyImmediate(transform.GetChild(i).gameObject);
        activeSensors.Clear();
        volumeBoundingBox = null;
    }

    void OnEnable()
    {
        InitRenderTexture();
        if (sensorData == null || sensorData.Length != 1024)
        {
            sensorData = new Vector4[1024];
            // 建议初始化为零，防止旧内存数据导致热力场出现莫名其妙的红点
            System.Array.Clear(sensorData, 0, sensorData.Length);
        }
    }
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