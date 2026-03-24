Shader "Custom/HeatRaymarching_MIP"
{
    Properties
    {
        _Opacity ("Overall Opacity", Range(0, 5)) = 1.0
        _Contrast ("Heat Contrast", Range(0, 10)) = 2.0
        _StepSize ("Step Size", Range(0.01, 0.2)) = 0.05
        [Toggle] _IsCylinder("Is Cylinder Shape", Float) = 0
    }
    SubShader
    {
        Tags { "RenderType"="Transparent" "Queue"="Transparent" "RenderPipeline"="UniversalPipeline" }
        
        // --- 关键修改：使用 Alpha 混合，但我们会手动控制颜色 ---
        Blend SrcAlpha OneMinusSrcAlpha 
        ZWrite Off
        Cull Front 

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes { float4 positionOS : POSITION; };
            struct Varyings { float4 positionCS : SV_POSITION; float3 positionOS : TEXCOORD0; };

            TEXTURE3D(_VolumeTexture);
            SAMPLER(sampler_VolumeTexture);
            float _Opacity, _Contrast, _StepSize, _IsCylinder;

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.positionOS = IN.positionOS.xyz;
                return OUT;
            }

            float3 HeatToColor(float h)
            {
                h = saturate(pow(h, _Contrast));
                float3 blue = float3(0, 0.2, 0.8);
                float3 green = float3(0, 0.8, 0.4);
                float3 yellow = float3(1, 0.9, 0);
                float3 red = float3(1, 0, 0);

                if (h < 0.25) return lerp(blue, green, h / 0.25);
                if (h < 0.5) return lerp(green, yellow, (h - 0.25) / 0.25);
                return lerp(yellow, red, saturate((h - 0.5) / 0.5));
            }

            float2 RayBoxDist(float3 ro, float3 rd, float3 boxMin, float3 boxMax) {
                float3 t0 = (boxMin - ro) / rd;
                float3 t1 = (boxMax - ro) / rd;
                float3 tmin = min(t0, t1);
                float3 tmax = max(t0, t1);
                return float2(max(max(tmin.x, tmin.y), tmin.z), min(min(tmax.x, tmax.y), tmax.z));
            }

            half4 frag(Varyings IN) : SV_Target
            {
                float3 ro = TransformWorldToObject(_WorldSpaceCameraPos);
                float3 rd = normalize(IN.positionOS - ro);

                float yBound = (_IsCylinder > 0.5) ? 1.0 : 0.5;
                float3 bMin = float3(-0.5, -yBound, -0.5);
                float3 bMax = float3(0.5, yBound, 0.5);

                float2 hit = RayBoxDist(ro, rd, bMin, bMax);
                float t = max(0, hit.x);
                float tMax = hit.y;

                // --- 核心逻辑：最大值投射 (MIP) ---
                float bestHeat = 0;
                float bestWeight = 0;

                for(int i=0; i<128; i++) {
                    if(t >= tMax) break;
                    
                    float3 p = ro + rd * t;
                    float3 uvw = p;
                    if(_IsCylinder > 0.5) uvw.y *= 0.5;
                    uvw += 0.5; 

                    if(all(uvw >= 0) && all(uvw <= 1)) {
                        float2 data = SAMPLE_TEXTURE3D_LOD(_VolumeTexture, sampler_VolumeTexture, uvw, 0).xy;
                        
                        // 记录整条视线上最热的数值
                        if(data.x > bestHeat) {
                            bestHeat = data.x;
                        }
                        // 记录最大权重决定不透明度
                        bestWeight = max(bestWeight, data.y);
                    }
                    t += _StepSize;
                }

                if(bestWeight < 0.01) discard;

                // 最终颜色只取决于整条路径上最热的点
                float3 finalRGB = HeatToColor(bestHeat);
                float finalAlpha = saturate(bestWeight * _Opacity);

                return half4(finalRGB, finalAlpha);
            }
            ENDHLSL
        }
    }
}