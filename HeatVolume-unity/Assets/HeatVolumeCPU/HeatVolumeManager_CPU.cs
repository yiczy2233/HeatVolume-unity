using UnityEngine;
using System.Collections.Generic;
using Unity.Jobs;
using Unity.Collections;

[ExecuteInEditMode]
public class HeatVolumeManager_CPU : MonoBehaviour
{
    public enum VolumeShape { Cube, Cylinder }
    private enum TempMode { Manual }

    [Header("1. 核心资源")]
    public Material raymarchingMaterial;
    public GameObject sensorPrefab;
    public GameObject[] ringVisualPrefabs;
    public GameObject pillarPrefab;

    [Header("2. 体积场物理属性")]
    public VolumeShape shapeType = VolumeShape.Cube;
    public Vector3 volumeSize = new Vector3(20, 10, 20);
    [Tooltip("WebGL建议设置在32-48之间以保证CPU性能")]
    public int textureResolution = 32; 
    public float sensorRadius = 3.0f;


    [Header("3. 阵列设置")]
    public Vector3Int gridCounts = new Vector3Int(5, 3, 5);
    [Range(0f, 1f)] public float gridPadding = 0.5f;
    public List<int> ringSettings = new List<int> { 4, 8, 12 };
    public int heightLayers = 5;
    public bool addCenterSensor = true;
    [Range(0f, 1f)] public float cylinderPadding = 0.15f;

    [Header("4. 真实数据配置")]
    public TextAsset realDataTextFile;

    

    // 【修改点2】：将 RenderTexture 替换为 Texture3D
    private Texture3D volumeTexture;
    private List<SensorNode> activeSensors = new List<SensorNode>();
    private Vector4[] sensorData = new Vector4[1024];
    private GameObject volumeBoundingBox;

    private int _lastResolution = 0;


    // ========================================================
    // 新增：C# Job System 实现的 IDW (反距离权重) 多线程计算核心
    // ========================================================
    public struct IDWJob : IJobParallelFor
    {
        [ReadOnly] public NativeArray<Vector4> sensors;
        public int sensorCount;
        public float radius;
        public Vector3 boundsMin;
        public Vector3 boundsSize;
        public int textureResolution;

        [WriteOnly] public NativeArray<Color32> outputColors;

        public void Execute(int index)
        {
            // 1D 索引转 3D 坐标
            int z = index / (textureResolution * textureResolution);
            int remainder = index % (textureResolution * textureResolution);
            int y = remainder / textureResolution;
            int x = remainder % textureResolution;

            Vector3 uvw = new Vector3(
                x / (float)(textureResolution - 1),
                y / (float)(textureResolution - 1),
                z / (float)(textureResolution - 1)
            );

            Vector3 worldPos = boundsMin + new Vector3(
                uvw.x * boundsSize.x,
                uvw.y * boundsSize.y,
                uvw.z * boundsSize.z
            );

            float sumWeights = 0f;
            float sumWeightedIntensity = 0f;
            float maxInfluence = 0f;

            for (int i = 0; i < sensorCount; i++)
            {
                Vector4 s = sensors[i];
                Vector3 sensorPos = new Vector3(s.x, s.y, s.z);
                float sensorTemp = s.w / 100.0f;

                float d = Vector3.Distance(worldPos, sensorPos);
                Vector3 diff = worldPos - sensorPos;

                // 计算权重
                float distSq = diff.x * diff.x + diff.y * diff.y + diff.z * diff.z;
                float w = 1.0f / (distSq + 0.001f);

                sumWeightedIntensity += sensorTemp * w;
                sumWeights += w;

                // 计算影响范围 (Alpha通道用)
                float influence = Mathf.Clamp01(1.0f - (d / (radius * 2.5f)));
                maxInfluence = Mathf.Max(maxInfluence, influence * influence);
            }

            float finalIntensity = (sumWeights > 0f) ? (sumWeightedIntensity / sumWeights) : 0f;

            // 转换为 Color32 (0-255) 节省内存，Shader 采样时会自动变为 0.0-1.0
            byte r = (byte)(Mathf.Clamp01(finalIntensity) * 255f);
            byte g = (byte)(Mathf.Clamp01(maxInfluence) * 255f);

            outputColors[index] = new Color32(r, g, 0, 0);
        }
    }


    // ========================================================
    // 数据同步与渲染
    // ========================================================
    void Update()
    {
        if (enableSimulation)
        {
            SimulateTemperatureTransition();
        }

        if (Input.GetKeyDown(KeyCode.A)) 
        {
            ApplyRealData(realDataTextFile.ToString());
        }
        
    }
    private void Start()
    {
        ApplyRealData(realDataTextFile.ToString());
    }

    // 2. 新增这个公共方法：只有调用它时，才会重新计算并生成一次 3D 热力场
    public void RefreshHeatMap()
    {
        // 检查是否需要重新生成贴图
        if (textureResolution != _lastResolution || volumeTexture == null)
        {
            InitTexture3D();
            _lastResolution = textureResolution;
        }

        if (activeSensors.Count == 0) return;

        // 收集所有传感器当前的位置和温度
        int count = Mathf.Min(activeSensors.Count, 1024);
        for (int i = 0; i < count; i++)
        {
            var sensor = activeSensors[i];
            if (sensor == null) continue;
            Vector3 worldP = sensor.transform.position;
            sensorData[i] = new Vector4(worldP.x, worldP.y, worldP.z, sensor.currentTemp);
        }

        // 触发 CPU 多线程计算，并把结果刷入 Texture3D
        CalculateVolumeCPU(count);
    }


    private void CalculateVolumeCPU(int count)
    {
        if (volumeTexture == null) return;

        int totalVoxels = textureResolution * textureResolution * textureResolution;

        // 分配临时内存给多线程 Job
        NativeArray<Vector4> jobSensors = new NativeArray<Vector4>(count, Allocator.TempJob);
        for (int i = 0; i < count; i++) jobSensors[i] = sensorData[i];

        NativeArray<Color32> jobColors = new NativeArray<Color32>(totalVoxels, Allocator.TempJob);

        // 初始化任务
        IDWJob job = new IDWJob
        {
            sensors = jobSensors,
            sensorCount = count,
            radius = sensorRadius,
            boundsMin = transform.position - volumeSize * 0.5f,
            boundsSize = volumeSize,
            textureResolution = textureResolution,
            outputColors = jobColors
        };

        // 调度并在同一帧等待完成 (由于用了 IJobParallelFor，这会自动分配到所有 CPU 核心)
        JobHandle handle = job.Schedule(totalVoxels, 64);
        handle.Complete();

        // 将算好的数据一次性应用到 Texture3D
        volumeTexture.SetPixelData(jobColors, 0);
        volumeTexture.Apply();

        // 释放临时内存
        jobSensors.Dispose();
        jobColors.Dispose();

        // 绑定给材质
        if (raymarchingMaterial != null)
        {
            raymarchingMaterial.SetTexture("_VolumeTexture", volumeTexture);
            raymarchingMaterial.SetMatrix("_WorldToLocal", transform.worldToLocalMatrix);
            raymarchingMaterial.SetFloat("_IsCylinder", shapeType == VolumeShape.Cylinder ? 1.0f : 0.0f);
        }
    }

    void OnEnable() { InitTexture3D(); }
    void OnDisable()
    {
        if (volumeTexture != null) DestroyImmediate(volumeTexture);
    }

    // 【修改点4】：创建普通 Texture3D 而非 RenderTexture
    void InitTexture3D()
    {
        if (volumeTexture != null) DestroyImmediate(volumeTexture);

        // RGBA32 格式在所有 WebGL 设备上 100% 兼容
        volumeTexture = new Texture3D(textureResolution, textureResolution, textureResolution, TextureFormat.RGBA32, false);
        volumeTexture.wrapMode = TextureWrapMode.Clamp;
        volumeTexture.filterMode = FilterMode.Bilinear;

        InitSnapshotTextures();
    }


    // ========================================================
    // 以下为你原有的解析逻辑、测试方法和数据结构（未作改动）
    // ========================================================
    

    [ContextMenu("R: 应用真实数据文件")]
    public void ApplyRealData(string rawText)
    {
        int jsonStartIndex = rawText.IndexOf('{');
        if (jsonStartIndex >= 0) rawText = rawText.Substring(jsonStartIndex);
        string cleanJson = rawText.Replace("\\\"", "\"");

        QYCRootData qycData = JsonUtility.FromJson<QYCRootData>(cleanJson);
        if (qycData != null && qycData.circle != null && qycData.circle.Count > 0)
        {
            ApplyQYCData(qycData);

            // 【修改点】：浅圆仓数据应用完毕，刷新一次热力图
            RefreshHeatMap();
            return;
        }

        PFCRootData pfcData = JsonUtility.FromJson<PFCRootData>(cleanJson);
        if (pfcData != null && pfcData.rows != null && pfcData.rows.Count > 0)
        {
            ApplyPFCData(pfcData);

            // 【修改点】：平房仓数据应用完毕，刷新一次热力图
            RefreshHeatMap();
            return;
        }

        Debug.LogError("真实数据解析失败：未识别出平房仓或浅圆仓的数据格式。");
    }

    private void ApplyQYCData(QYCRootData data)
    {
        shapeType = VolumeShape.Cylinder;
        CreateBoundingBox();

        int maxLayer = 0;
        int totalPoints = 0;
        foreach (var circle in data.circle)
        {
            if (circle.cable == null) continue;
            foreach (var cable in circle.cable)
            {
                if (cable.point == null) continue;
                foreach (var pt in cable.point)
                {
                    totalPoints++;
                    if (pt.layer > maxLayer) maxLayer = pt.layer;
                }
            }
        }

        if (totalPoints == 0) return;

        float maxRadiusX = (volumeSize.x * 0.5f) * (1f - cylinderPadding);
        float maxRadiusZ = (volumeSize.z * 0.5f) * (1f - cylinderPadding);
        float spacingY = maxLayer > 1 ? volumeSize.y / (maxLayer - 1 + (gridPadding * 2f)) : 0;
        float startOffsetY = -volumeSize.y * 0.5f + ((maxLayer > 1) ? spacingY * gridPadding : volumeSize.y * 0.5f);

        foreach (var circle in data.circle)
        {
            float normalizedRadius = circle.radius;
            if (circle.cable == null) continue;

            int cableCount = circle.cable.Count;
            for (int c = 0; c < cableCount; c++)
            {
                var cable = circle.cable[c];
                float angle = c * (2 * Mathf.PI / cableCount);

                float xPos = Mathf.Cos(angle) * maxRadiusX * normalizedRadius;
                float zPos = Mathf.Sin(angle) * maxRadiusZ * normalizedRadius;

                if (cable.point == null) continue;
                foreach (var pt in cable.point)
                {
                    int yIdx = pt.layer - 1;
                    float yPos = startOffsetY + yIdx * spacingY;
                    Vector3 localPos = new Vector3(xPos, yPos, zPos);

                    float parsedTemp = 0f;
                    float.TryParse(pt.value, out parsedTemp);

                    int cableNum = 0;
                    int.TryParse(cable.number, out cableNum);

                    SpawnSensor(localPos, $"S_QYC_R{pt.ring}_C{cable.number}_L{pt.layer}");
                    SensorNode node = activeSensors[activeSensors.Count - 1];

                    node.SetFullData(parsedTemp, pt.status, pt.statusName, pt.color, pt.ring, cableNum, pt.layer);

                }
            }
        }
    }

    private void ApplyPFCData(PFCRootData data)
    {
        shapeType = VolumeShape.Cube;
        CreateBoundingBox();

        List<PFCPointData> allPoints = new List<PFCPointData>();
        int maxRow = 0, maxCol = 0, maxLayer = 0;

        foreach (var r in data.rows)
        {
            if (r.cols == null) continue;
            foreach (var c in r.cols)
            {
                if (c.points == null) continue;
                foreach (var p in c.points)
                {
                    allPoints.Add(p);
                    if (p.row > maxRow) maxRow = p.row;
                    if (p.col > maxCol) maxCol = p.col;
                    if (p.layer > maxLayer) maxLayer = p.layer;
                }
            }
        }

        if (allPoints.Count == 0) return;

        gridCounts = new Vector3Int(maxCol, maxLayer, maxRow);
        Vector3 spacing = Vector3.zero;
        Vector3 startOffset = -volumeSize / 2f;

        spacing.x = maxCol > 1 ? volumeSize.x / (maxCol - 1 + (gridPadding * 2f)) : 0;
        spacing.y = maxLayer > 1 ? volumeSize.y / (maxLayer - 1 + (gridPadding * 2f)) : 0;
        spacing.z = maxRow > 1 ? volumeSize.z / (maxRow - 1 + (gridPadding * 2f)) : 0;

        startOffset.x += (maxCol > 1) ? spacing.x * gridPadding : volumeSize.x * 0.5f;
        startOffset.y += (maxLayer > 1) ? spacing.y * gridPadding : volumeSize.y * 0.5f;
        startOffset.z += (maxRow > 1) ? spacing.z * gridPadding : volumeSize.z * 0.5f;

        foreach (var pt in allPoints)
        {
            int xIdx = pt.col - 1;
            int yIdx = pt.layer - 1;
            int zIdx = pt.row - 1;

            Vector3 localPos = startOffset + new Vector3(xIdx * spacing.x, yIdx * spacing.y, zIdx * spacing.z);
            SpawnSensor(localPos, $"S_PFC_R{pt.row}_C{pt.col}_L{pt.layer}");

            SensorNode node = activeSensors[activeSensors.Count - 1];
            float parsedTemp = 25f;
            float.TryParse(pt.value, out parsedTemp);

            node.SetFullData(parsedTemp, pt.status, pt.statusName, pt.color, pt.row, pt.col, pt.layer);
        }
    }
    //应用通风后的目标数据
    public void ApplyTargetData(string targetRawText)
    {
        string cleanJson = targetRawText.Replace("\\\"", "\"");
        PFCRootData pfcData = JsonUtility.FromJson<PFCRootData>(cleanJson);

        // 建立一个名字查找表，提高匹配效率
        Dictionary<string, SensorNode> lookup = new Dictionary<string, SensorNode>();
        foreach (var s in activeSensors) if (s != null) lookup[s.name] = s;

        foreach (var r in pfcData.rows)
        {
            foreach (var c in r.cols)
            {
                foreach (var pt in c.points)
                {
                    string key = $"S_PFC_R{pt.row}_C{pt.col}_L{pt.layer}";
                    if (lookup.TryGetValue(key, out SensorNode node))
                    {
                        float.TryParse(pt.value, out float tV);
                        node.targetTemp = tV; // 明确设置模拟的终点
                    }
                }
            }
        }
        Debug.Log("通风目标温度加载完成，等待模拟开启...");
    }

    private void SetQYCTargetTemperatures(QYCRootData data)
    {
        // 建立 名字 -> 目标温度 的字典
        Dictionary<string, float> targetTempMap = new Dictionary<string, float>();

        foreach (var circle in data.circle)
        {
            if (circle.cable == null) continue;
            foreach (var cable in circle.cable)
            {
                if (cable.point == null) continue;
                foreach (var pt in cable.point)
                {
                    float.TryParse(pt.value, out float parsedTemp);
                    // 构造与生成时完全相同的名字
                    string sensorName = $"S_QYC_R{pt.ring}_C{cable.number}_L{pt.layer}";
                    targetTempMap[sensorName] = parsedTemp;
                }
            }
        }
        ApplyTargetsToSensors(targetTempMap);
    }

    private void SetPFCTargetTemperatures(PFCRootData data)
    {
        Dictionary<string, float> targetTempMap = new Dictionary<string, float>();

        foreach (var r in data.rows)
        {
            if (r.cols == null) continue;
            foreach (var c in r.cols)
            {
                if (c.points == null) continue;
                foreach (var pt in c.points)
                {
                    float.TryParse(pt.value, out float parsedTemp);
                    string sensorName = $"S_PFC_R{pt.row}_C{pt.col}_L{pt.layer}";
                    targetTempMap[sensorName] = parsedTemp;
                }
            }
        }
        ApplyTargetsToSensors(targetTempMap);
    }

    private void ApplyTargetsToSensors(Dictionary<string, float> targetMap)
    {
        int matchCount = 0;
        foreach (var sensor in activeSensors)
        {
            if (sensor == null) continue;

            // 如果字典里有这个传感器的名字，就把温度赋给它的 targetTemp
            if (targetMap.TryGetValue(sensor.gameObject.name, out float target))
            {
                sensor.targetTemp = target;
                matchCount++;
            }
            else
            {
                // 如果新数据里没找到这个点，目标温度就保持当前温度，让它不要动
                sensor.targetTemp = sensor.currentTemp;
            }
        }
        Debug.Log($"应用模拟数据完成：成功匹配并设置了 {matchCount} 个传感器的目标温度。");
    }



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
        volumeBoundingBox.layer = this.gameObject.layer;
        DestroyImmediate(volumeBoundingBox.GetComponent<Collider>());
        if (raymarchingMaterial != null) volumeBoundingBox.GetComponent<MeshRenderer>().sharedMaterial = raymarchingMaterial;
    }

    private void SpawnSensor(Vector3 localPos, string name)
    {
        if (sensorPrefab == null) return;
        Quaternion rot = Quaternion.identity;
        if (shapeType == VolumeShape.Cylinder)
        {
            Vector3 dir = new Vector3(0, localPos.y, 0) - localPos;
            if (dir != Vector3.zero) rot = Quaternion.LookRotation(transform.TransformDirection(dir));
        }
        GameObject go = Instantiate(sensorPrefab, transform.TransformPoint(localPos), rot, transform);
        go.name = name;
        go.layer = this.gameObject.layer;
        SensorNode node = go.GetComponent<SensorNode>() ?? go.AddComponent<SensorNode>();
        activeSensors.Add(node);
    }


    [Header("5. 模拟设置")]
    public bool enableSimulation = false;
    public float simulationSpeed = 2.0f; // 每秒温度变化的速度

    /// <summary>
    /// 模拟动态温度变化：
    /// </summary>
    public void SimulateTemperatureTransition()
    {
        if (!enableSimulation) return;

        bool hasChanged = false;
        float step = Time.deltaTime * simulationSpeed;

        foreach (var sensor in activeSensors)
        {
            if (sensor == null) continue;

            // 如果这两个值不相等，说明需要发生“通风热交换”
            if (!Mathf.Approximately(sensor.currentTemp, sensor.targetTemp))
            {
                float nextTemp = Mathf.MoveTowards(sensor.currentTemp, sensor.targetTemp, step);
                sensor.UpdateTemperature(nextTemp); // 更新数值和颜色
                hasChanged = true;
            }
        }

        if (hasChanged) RefreshHeatMap();
    }
    // --- 新增：用于存储快照的贴图 ---
    private Texture3D textureSnapBefore;
    private Texture3D textureSnapAfter;

    // 在 InitTexture3D 中初始化它们
    void InitSnapshotTextures()
    {
        if (textureSnapBefore != null) DestroyImmediate(textureSnapBefore);
        if (textureSnapAfter != null) DestroyImmediate(textureSnapAfter);

        textureSnapBefore = new Texture3D(textureResolution, textureResolution, textureResolution, TextureFormat.RGBA32, false);
        textureSnapAfter = new Texture3D(textureResolution, textureResolution, textureResolution, TextureFormat.RGBA32, false);

        textureSnapBefore.filterMode = FilterMode.Bilinear;
        textureSnapAfter.filterMode = FilterMode.Bilinear;
    }

    // 调用此方法记录“通风前”
    public void RecordBeforeState()
    {
        if (volumeTexture != null) Graphics.CopyTexture(volumeTexture, textureSnapBefore);
    }

    // 调用此方法记录“通风后”
    public void RecordAfterState()
    {
        if (volumeTexture != null) Graphics.CopyTexture(volumeTexture, textureSnapAfter);
    }

    // 切换显示模式：0-实时, 1-通风前, 2-通风后
    public void SetDisplayMode(int mode)
    {
        if (raymarchingMaterial == null) return;

        switch (mode)
        {
            case 0: // 实时模式
                raymarchingMaterial.SetTexture("_VolumeTexture", volumeTexture);
                break;
            case 1: // 显示通风前快照
                raymarchingMaterial.SetTexture("_VolumeTexture", textureSnapBefore);
                break;
            case 2: // 显示通风后快照
                raymarchingMaterial.SetTexture("_VolumeTexture", textureSnapAfter);
                break;
        }
    }

}

// ---------------- 解析用的 JSON 结构保留 ----------------
[System.Serializable] public class QYCRootData { public List<QYCCircleData> circle; }
[System.Serializable] public class QYCCircleData { public float radius; public List<QYCCableData> cable; }
[System.Serializable] public class QYCCableData { public string number; public List<PFCPointData> point; }
[System.Serializable] public class PFCRootData { public List<PFCRowData> rows; }
[System.Serializable] public class PFCRowData { public List<PFCColData> cols; }
[System.Serializable] public class PFCColData { public List<PFCPointData> points; public string num; }
[System.Serializable] public class PFCPointData { public string value; public string status; public string statusName; public string color; public int row; public int col; public int layer; public int ring; }