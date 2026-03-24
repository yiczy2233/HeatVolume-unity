Shader "Custom/HeatRaymarching_Rainbow_Fluid"
{
    Properties
    {
        _Opacity ("Overall Opacity", Range(0, 10)) = 1.0
        _ColorDist ("Color Distribution", Range(0.1, 5)) = 1.0
        _StepSize ("Step Size", Range(0.01, 0.2)) = 0.05
        _GlowIntensity ("Glow Intensity (HDR)", Range(1, 10)) = 2.0
        _NoiseScale ("Fluid Scale", Range(0, 10)) = 3.0
        _NoiseSpeed ("Fluid Speed", Range(0, 2)) = 0.5
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
            float _Opacity, _ColorDist, _StepSize, _IsCylinder, _GlowIntensity, _NoiseScale, _NoiseSpeed;

            float SimpleNoise(float3 p) {
                float3 i = floor(p);
                float3 f = frac(p);
                f = f * f * (3.0 - 2.0 * f);
                float n = i.x + i.y * 57.0 + 113.0 * i.z;
                float4 res = lerp(
                    lerp(lerp(frac(sin(n + 0.0) * 43758.5453), frac(sin(n + 1.0) * 43758.5453), f.x),
                         lerp(frac(sin(n + 57.0) * 43758.5453), frac(sin(n + 58.0) * 43758.5453), f.x), f.y),
                    lerp(lerp(frac(sin(n + 113.0) * 43758.5453), frac(sin(n + 114.0) * 43758.5453), f.x),
                         lerp(frac(sin(n + 170.0) * 43758.5453), frac(sin(n + 171.0) * 43758.5453), f.x), f.y), f.z);
                return res.x;
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.positionOS = IN.positionOS.xyz;
                OUT.screenPos = ComputeScreenPos(OUT.positionCS);
                return OUT;
            }

            float3 HeatToColor(float h)
            {
                float t = saturate(h);
                // 使用 ColorDist 微调色块占比
                if(_ColorDist != 1.0) t = pow(t, 1.0 / _ColorDist); 

                float3 darkBlue = float3(0.0, 0.0, 0.4); 
                float3 cyan     = float3(0.0, 0.8, 1.0); 
                float3 green    = float3(0.0, 1.0, 0.2); 
                float3 yellow   = float3(1.0, 0.9, 0.0); 
                float3 orange   = float3(1.0, 0.4, 0.0); 
                float3 red      = float3(1.0, 0.0, 0.0); 
                float3 white    = float3(1.5, 1.3, 1.1); 

                float3 col;
                if (t < 0.2) col = lerp(darkBlue, cyan, t / 0.2);
                else if (t < 0.4) col = lerp(cyan, green, (t - 0.2) / 0.2);
                else if (t < 0.6) col = lerp(green, yellow, (t - 0.4) / 0.2);
                else if (t < 0.8) col = lerp(yellow, orange, (t - 0.6) / 0.2);
                else if (t < 0.92) col = lerp(orange, red, (t - 0.8) / 0.12);
                else col = lerp(red, white, (t - 0.92) / 0.08);

                float glow = smoothstep(0.7, 1.0, t) * _GlowIntensity;
                return col * (1.0 + glow);
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

                float2 uvScreen = IN.screenPos.xy / IN.screenPos.w;
                t += (frac(sin(dot(uvScreen, float2(12.9898, 78.233))) * 43758.5453)) * _StepSize;

                float bestHeat = 0;
                float bestWeight = 0;

                for(int i=0; i<128; i++) {
                    if(t >= tMax) break;
                    float3 p = ro + rd * t;

                    // --- 优化：纵向拉伸噪声，产生升腾感 ---
                    float3 nCoord = p * _NoiseScale;
                    nCoord.y *= 0.5; // Y轴噪声频率减半，产生纵向拉伸效果
                    float noise = SimpleNoise(nCoord - float3(0, _Time.y * _NoiseSpeed, 0)) * 0.05;
                    
                    float3 uvw = p + noise;
                    if(_IsCylinder > 0.5) uvw.y *= 0.5;
                    uvw += 0.5; 

                    if(all(uvw >= 0) && all(uvw <= 1)) {
                        float2 data = SAMPLE_TEXTURE3D_LOD(_VolumeTexture, sampler_VolumeTexture, uvw, 0).xy;
                        if(data.x > bestHeat) bestHeat = data.x;
                        bestWeight = max(bestWeight, data.y);
                    }
                    t += _StepSize;
                }

                if(bestWeight < 0.01) discard;

                float3 finalRGB = HeatToColor(bestHeat);
                
                // 优化透明度：让低温区更透明，核心区更稳重
                float alphaBoost = lerp(0.5, 1.2, bestHeat);
                float finalAlpha = saturate(bestWeight * _Opacity * alphaBoost);

                return half4(finalRGB, finalAlpha);
            }
            ENDHLSL
        }
    }
}