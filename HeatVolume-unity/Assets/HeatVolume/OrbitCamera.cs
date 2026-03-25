using UnityEngine;
using UnityEngine.InputSystem;

public class OrbitCamera : MonoBehaviour
{
    [Header("1. 目标设置")]
    public Transform target;           // 旋转中心
    public Vector3 offset = Vector3.zero;

    [Header("2. 灵敏度设置")]
    public float rotationSpeed = 0.2f;
    public float panSpeed = 0.05f;
    public float zoomSpeed = 5.0f;

    [Header("3. 阻尼/平滑设置")]
    [Range(0.01f, 1f)]
    public float smoothTime = 0.1f;    // 数值越小越紧跟，数值越大阻尼感越强
    public bool useSmoothing = true;

    [Header("4. 限制设置")]
    public float minDistance = 2f;
    public float maxDistance = 50f;
    public float minPolarAngle = 5f;
    public float maxPolarAngle = 85f;

    // 目标状态（用户输入决定的理想位置）
    private Vector2 targetRotation;
    private float targetDistance;
    private Vector3 targetPanPos;

    // 当前状态（实际相机所在的位置，随时间向目标状态逼近）
    private Vector2 currentRotation;
    private float currentDistance;
    private Vector3 currentPanPos;

    // SmoothDamp 辅助变量
    private Vector2 rotationVelocity;
    private float zoomVelocity;
    private Vector3 panVelocity;

    void Start()
    {
        if (target != null)
        {
            targetPanPos = target.position + offset;
            Vector3 angles = transform.eulerAngles;
            targetRotation.x = angles.y;
            targetRotation.y = angles.x;
            targetDistance = Vector3.Distance(transform.position, targetPanPos);

            // 初始化当前状态，防止开局瞬移
            currentRotation = targetRotation;
            currentDistance = targetDistance;
            currentPanPos = targetPanPos;
        }
    }

    void LateUpdate()
    {
        if (target == null) return;

        var mouse = Mouse.current;
        if (mouse == null) return;

        HandleInput(mouse);
        ApplySmoothing();
        UpdateTransform();
    }

    private void HandleInput(Mouse mouse)
    {
        // 1. 旋转输入 (左键)
        if (mouse.leftButton.isPressed)
        {
            Vector2 delta = mouse.delta.ReadValue();
            targetRotation.x += delta.x * rotationSpeed;
            targetRotation.y -= delta.y * rotationSpeed;
            targetRotation.y = Mathf.Clamp(targetRotation.y, minPolarAngle, maxPolarAngle);
        }

        // 2. 平移输入 (右键)
        if (mouse.rightButton.isPressed)
        {
            Vector2 delta = mouse.delta.ReadValue();
            Vector3 right = transform.right * (-delta.x * panSpeed);
            Vector3 up = transform.up * (-delta.y * panSpeed);
            targetPanPos += right + up;
        }

        // 3. 缩放输入 (滚轮)
        float scroll = mouse.scroll.ReadValue().y;
        if (Mathf.Abs(scroll) > 0.01f)
        {
            targetDistance -= scroll * zoomSpeed * 0.01f;
            targetDistance = Mathf.Clamp(targetDistance, minDistance, maxDistance);
        }
    }

    private void ApplySmoothing()
    {
        if (useSmoothing)
        {
            // 使用 SmoothDamp 模拟弹簧阻尼效果
            currentRotation.x = Mathf.SmoothDampAngle(currentRotation.x, targetRotation.x, ref rotationVelocity.x, smoothTime);
            currentRotation.y = Mathf.SmoothDampAngle(currentRotation.y, targetRotation.y, ref rotationVelocity.y, smoothTime);

            currentDistance = Mathf.SmoothDamp(currentDistance, targetDistance, ref zoomVelocity, smoothTime);

            currentPanPos = Vector3.SmoothDamp(currentPanPos, targetPanPos, ref panVelocity, smoothTime);
        }
        else
        {
            currentRotation = targetRotation;
            currentDistance = targetDistance;
            currentPanPos = targetPanPos;
        }
    }

    private void UpdateTransform()
    {
        // 计算最终变换
        Quaternion lookRotation = Quaternion.Euler(currentRotation.y, currentRotation.x, 0);
        Vector3 position = lookRotation * new Vector3(0, 0, -currentDistance) + currentPanPos;

        transform.rotation = lookRotation;
        transform.position = position;
    }
}