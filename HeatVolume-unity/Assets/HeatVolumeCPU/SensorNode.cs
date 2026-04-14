using TMPro;
using UnityEngine;
using UnityEngine.SceneManagement;

[RequireComponent(typeof(MeshRenderer))]
public class SensorNode : MonoBehaviour
{
    [Header("核心数据")]
    public float currentTemp = 25f;
    public float targetTemp;

    [Header("平房仓业务数据")]
    public string status;
    public string statusName;
    public string pointColor;
    public int row;
    public int col;
    public int layer;
    public string num;

    [Header("视觉颜色")]
    [ColorUsage(true, true)] public Color coldColor = Color.blue;
    [ColorUsage(true, true)] public Color normalColor = Color.green;
    [ColorUsage(true, true)] public Color hotColor = Color.red;

    [Header("UI 引用")]
    public GameObject wkUI;

    private Color originalPointColor;
    private MeshRenderer _renderer;
    private MaterialPropertyBlock _mpb;
    private static readonly int BaseColorId = Shader.PropertyToID("_BaseColor");
    private string currentSceneName;

    private void Awake()
    {
        _renderer = GetComponent<MeshRenderer>();
        _mpb = new MaterialPropertyBlock();
        currentSceneName = SceneManager.GetActiveScene().name;
    }

    private void Start()
    {
        // 仅在 pfc 1 场景自动找 UI，pfc 2 由 Manager 分配
        if (currentSceneName == "pfc 1" && wkUI == null)
        {
            GameObject canvasObj = GameObject.Find("Canvas");
            if (canvasObj != null)
            {
                Transform target = canvasObj.transform.Find("WKUI");
                if (target != null)
                {
                    wkUI = target.gameObject;
                    wkUI.SetActive(false);
                }
            }
        }
    }

    public void SetFullData(float temp, string stat, string sName, string pCol, int r, int c, int l, string nodeNum = "")
    {
        this.currentTemp = temp;
        this.status = stat;
        this.statusName = sName;
        this.pointColor = pCol;
        this.row = r;
        this.col = c;
        this.layer = l;
        this.num = nodeNum;
        UpdateTemperature(temp);
    }

    public void UpdateTemperature(float temp)
    {
        currentTemp = temp;
        if (_renderer == null) _renderer = GetComponent<MeshRenderer>();
        if (_mpb == null) _mpb = new MaterialPropertyBlock();

        Color targetColor = normalColor;
        if (temp <= 10f) targetColor = coldColor;
        else if (temp >= 35f) targetColor = hotColor;

        _mpb.SetColor(BaseColorId, targetColor);
        _renderer.SetPropertyBlock(_mpb);
        originalPointColor = targetColor;
    }

    #region 鼠标交互逻辑

    void OnMouseEnter()
    {
        if (currentSceneName == "pfc 1") HandleMouseEnter(wkUI, Input.mousePosition);
    }

    void OnMouseExit()
    {
        if (currentSceneName == "pfc 1") HandleMouseExit(wkUI);
    }

    // 核心显示方法：显示“我”的数据到指定的 UI 上
    public void HandleMouseEnter(GameObject targetUI, Vector3 pointerPosition)
    {
        // 高亮模型
        _mpb.SetColor(BaseColorId, Color.yellow);
        _renderer.SetPropertyBlock(_mpb);

        if (targetUI != null)
        {
            targetUI.SetActive(true);
            Transform sj = targetUI.transform.Find("SJ");
            if (sj != null)
            {
                // 【关键】这里使用的全部是 this (当前被射中的点) 的数据
                UpdateUIText(sj, 0, this.currentTemp.ToString("F1") + "℃");
                UpdateUIText(sj, 1, this.layer.ToString());
                UpdateUIText(sj, 2, this.row.ToString());
                UpdateUIText(sj, 3, this.col.ToString());
                UpdateUIText(sj, 4, this.statusName);
            }
            targetUI.transform.position = pointerPosition;
        }
    }

    public void HandleMouseExit(GameObject targetUI)
    {
        _mpb.SetColor(BaseColorId, originalPointColor);
        _renderer.SetPropertyBlock(_mpb);
        if (targetUI != null) targetUI.SetActive(false);
    }

    private void UpdateUIText(Transform parent, int index, string text)
    {
        if (index < parent.childCount)
        {
            var tmp = parent.GetChild(index).GetComponent<TextMeshProUGUI>();
            if (tmp != null) tmp.text = text;
        }
    }
    #endregion
}