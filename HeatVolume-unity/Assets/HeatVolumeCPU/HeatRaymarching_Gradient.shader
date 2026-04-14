Shader "Custom/HeatRaymarching_Gradient"
{
    Properties
    {
        [Header(General Settings)]
        _Opacity ("Overall Intensity", Range(0, 10)) = 1.5
        _StepSize ("Raymarching Step Size", Range(0.01, 0.2)) = 0.05
        
        [Header(Visual Effects)]
        _GlowIntensity ("Hot Spot Glow (HDR)", Range(1, 10)) = 2.5
        _NoiseScale ("Fluid Pattern Scale", Range(0, 10)) = 2.2
        _NoiseSpeed ("Fluid Rise Speed", Range(0, 2)) = 0.3
        _Distortion ("Hot Spot Turbulence", Range(0, 0.1)) = 0.015
        
        [Toggle] _IsCylinder("Is Cylinder Shape", Float) = 0
    }
    SubShader
    {
        Tags { "RenderType"="Transparent" "Queue"="Transparent" "RenderPipeline"="UniversalPipeline" }
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
            struct Varyings { 
                float4 positionCS : SV_POSITION;
                float3 positionOS : TEXCOORD0; 
                float4 screenPos : TEXCOORD1;
            };

            TEXTURE3D(_VolumeTexture);
            SAMPLER(sampler_VolumeTexture);
            float _Opacity, _StepSize, _IsCylinder, _GlowIntensity, _NoiseScale, _NoiseSpeed, _Distortion;

            float remap(float value, float low1, float high1, float low2, float high2) {
                return low2 + (value - low1) * (high2 - low2) / (high1 - low1);
            }

            float hash(float n) { return frac(sin(n) * 43758.5453); }
            
            float noise(float3 x) {
                float3 p = floor(x);
                float3 f = frac(x);
                f = f * f * (3.0 - 2.0 * f);
                float n = p.x + p.y * 57.0 + 113.0 * p.z;
                return lerp(lerp(lerp(hash(n + 0.0), hash(n + 1.0), f.x),
                                 lerp(hash(n + 57.0), hash(n + 58.0), f.x), f.y),
                            lerp(lerp(hash(n + 113.0), hash(n + 114.0), f.x),
                              lerp(hash(n + 170.0), hash(n + 171.0), f.x), f.y), f.z);
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.positionOS = IN.positionOS.xyz;
                OUT.screenPos = ComputeScreenPos(OUT.positionCS);
                return OUT;
            }

            // 1. 还原所有精细分层颜色
            float3 GradientHeatToColor(float h)
            {
                float temp = saturate(h) * 100.0;
                if (temp >= 40.0) return float3(0.596, 0.020, 0.000); 
                if (temp >= 38.0) return float3(0.627, 0.035, 0.004); 
                if (temp >= 36.0) return float3(0.765, 0.047, 0.008); 
                if (temp >= 34.0) return float3(0.859, 0.306, 0.000); 
                if (temp >= 32.0) return float3(0.945, 0.553, 0.008); 
                if (temp >= 30.0) return float3(0.925, 0.788, 0.020); 
                if (temp >= 28.0) return float3(0.914, 0.925, 0.020); 
                if (temp >= 26.0) return float3(0.706, 0.843, 0.063); 
                if (temp >= 24.0) return float3(0.439, 0.749, 0.000); 
                if (temp >= 22.0) return float3(0.051, 0.749, 0.000); 
                if (temp >= 20.0) return float3(0.063, 0.820, 0.008); 
                if (temp >= 18.0) return float3(0.004, 0.894, 0.318); 
                if (temp >= 16.0) return float3(0.000, 0.761, 0.643); 
                if (temp >= 14.0) return float3(0.294, 0.796, 0.855); 
                if (temp >= 12.0) return float3(0.365, 0.824, 0.996); 
                if (temp >= 10.0) return float3(0.118, 0.753, 0.992); 
                if (temp >= 8.0)  return float3(0.169, 0.639, 0.992); 
                if (temp >= 6.0)  return float3(0.004, 0.486, 0.851); 
                if (temp >= 4.0)  return float3(0.000, 0.408, 0.718); 
                if (temp >= 2.0)  return float3(0.000, 0.278, 0.616); 
                return float3(0.000, 0.161, 0.365); 
            }

            // 2. 优先级排序：红黄 > 蓝 > 绿
            float GetGradientPriority(float h)
            {
                float temp = saturate(h) * 100.0;
                // 高温大区：最优先
                if (temp >= 28.0) return 1000.0 + temp;
                // 低温大区：次优先 (20度以下)
                if (temp < 20.0)  return 500.0 + (20.0 - temp); 
                // 绿色大区：最后
                return 100.0 + temp;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                float3 ro = TransformWorldToObject(_WorldSpaceCameraPos);
                float3 rd = normalize(IN.positionOS - ro);
                
                float yBound = (_IsCylinder > 0.5) ? 1.0 : 0.5;
                float3 bMin = float3(-0.5, -yBound, -0.5);
                float3 bMax = float3(0.5, yBound, 0.5);
                float3 t0 = (bMin - ro) / rd;
                float3 t1 = (bMax - ro) / rd;
                float tMax = min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z));
                float t = max(0, max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z)));
                
                t += (frac(sin(dot(IN.screenPos.xy/IN.screenPos.w, float2(12.9898, 78.233))) * 43758.5453)) * _StepSize;

                float maxPriority = -1.0;
                float finalHeat = 0;
                float totalWeight = 0;

                for(int i=0; i<70; i++) {
                    if(t >= tMax) break;
                    float3 p = ro + rd * t;
                    
                    float noiseVal = noise(p * _NoiseScale - float3(0, _Time.y * _NoiseSpeed, 0));
                    float3 uvw = p + (noiseVal - 0.5) * _Distortion;
                    if(_IsCylinder > 0.5) uvw.y *= 0.5;
                    uvw += 0.5;

                    if(all(uvw >= 0) && all(uvw <= 1)) {
                        float2 sampleData = SAMPLE_TEXTURE3D_LOD(_VolumeTexture, sampler_VolumeTexture, uvw, 0).xy;
                        float heat = sampleData.x;
                        float weight = sampleData.y;

                        if(weight > 0.01) {
                            float pty = GetGradientPriority(heat);
                            if(pty > maxPriority) {
                                maxPriority = pty;
                                finalHeat = heat; 
                            }
                            totalWeight = max(totalWeight, weight);
                        }
                    }
                    t += _StepSize;
                }

                if(maxPriority < 0) discard;

                float3 color = GradientHeatToColor(finalHeat);
                
                // 高温强化
                if(finalHeat * 100.0 >= 28.0) {
                    color *= (1.0 + smoothstep(0.28, 1.0, finalHeat) * _GlowIntensity);
                }

                float alpha = saturate(totalWeight * _Opacity);
                return half4(color, alpha);
            }
            ENDHLSL
        }
    }
}