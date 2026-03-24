Shader "Custom/SensorNode_SciFi"
{
    Properties
    {
        // _BaseColor 和 _EmissionColor 必须保留，供脚本 MPB 驱动颜色
        [HDR] _BaseColor("Base Color", Color) = (1,1,1,1)
        [HDR] _EmissionColor("Emission Color", Color) = (0,0,0,0)
        
        [Header(Visual Style)]
        _FresnelPower("Fresnel Range", Range(0.5, 8.0)) = 4.0
        _PulseSpeed("Pulse Speed", Range(0, 10)) = 2.0
        _PulseMinOpacity("Pulse Min Opacity", Range(0, 1)) = 0.5
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" "Queue"="Geometry" }
        
        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            // 必须开启合批支持
            #pragma multi_compile_instancing 

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL; // 需要法线
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 normalWS : TEXCOORD0;
                float3 viewDirWS : TEXCOORD1;
                UNITY_VERTEX_INPUT_INSTANCE_ID
            };

            // 属性定义为了合批兼容
            CBUFFER_START(UnityPerMaterial)
                half _FresnelPower;
                half _PulseSpeed;
                half _PulseMinOpacity;
            CBUFFER_END

            // 动态变色 ID Buffer
            UNITY_INSTANCING_BUFFER_START(Props)
                UNITY_DEFINE_INSTANCED_PROP(float4, _BaseColor)
                UNITY_DEFINE_INSTANCED_PROP(float4, _EmissionColor)
            UNITY_INSTANCING_BUFFER_END(Props)

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                UNITY_SETUP_INSTANCE_ID(IN);
                UNITY_TRANSFER_INSTANCE_ID(IN, OUT);

                float3 worldPos = TransformObjectToWorld(IN.positionOS.xyz);
                OUT.positionCS = TransformWorldToHClip(worldPos);
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                OUT.viewDirWS = GetWorldSpaceViewDir(worldPos);
                
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                UNITY_SETUP_INSTANCE_ID(IN);
                
                half4 col = UNITY_ACCESS_INSTANCED_PROP(Props, _BaseColor);
                half4 emi = UNITY_ACCESS_INSTANCED_PROP(Props, _EmissionColor);

                // 1. 菲涅尔边缘探测 (越边缘数值越高)
                float3 normal = normalize(IN.normalWS);
                float3 viewDir = normalize(IN.viewDirWS);
                half fresnel = pow(1.0 - saturate(dot(normal, viewDir)), _FresnelPower);

                // 2. 呼吸效果 (随时间闪烁，驱动总亮度)
                // 基于时间的正弦波 [PulseMinOpacity, 1.0]
                half pulse = _PulseMinOpacity + (sin(_Time.y * _PulseSpeed) * 0.5 + 0.5) * (1.0 - _PulseMinOpacity);

                // 3. 颜色合成：
                // (基础色 + 自发光 + 边缘高亮) * 呼吸系数
                // 这里加重了 Fresnel 的比重，增强边缘感
                half3 scifiColor = col.rgb + emi.rgb + col.rgb * fresnel * 2.0;
                half3 finalRGB = scifiColor * pulse;

                return half4(finalRGB, col.a);
            }
            ENDHLSL
        }
    }
}