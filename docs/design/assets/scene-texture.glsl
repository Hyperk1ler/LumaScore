#version 100
precision highp float;
/**
 * @resolution
 */
uniform vec2 u_resolution;
/**
 * @label Background
 * @color
 * @default #07122e
 */
uniform vec3 u_bg;
/**
 * @label Grid ink
 * @color
 * @default #6591d9
 */
uniform vec3 u_ink;
/**
 * @label Texture strength
 * @range 0, 1
 * @default 0.55
 */
uniform float u_strength;
/**
 * @label Grid spacing
 * @range 24, 120
 * @default 64
 */
uniform float u_spacing;
/**
 * @label Grain
 * @range 0, 1
 * @default 0.12
 */
uniform float u_grain;
/**
 * @label Orbital rings
 * @range 0, 1
 * @default 1
 */
uniform float u_rings;
/**
 * @label Ring center
 */
uniform vec2 u_origin;
float hash(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
float line(float v,float s){float d=mod(v,s);return 1.0-smoothstep(0.4,1.2,min(d,s-d));}
void main(){
 vec2 p=gl_FragCoord.xy;
 float fine=max(line(p.x,u_spacing*0.25),line(p.y,u_spacing*0.25));
 float major=max(line(p.x,u_spacing),line(p.y,u_spacing));
 vec2 q=p-u_resolution*u_origin;
 float r=length(q);
 float rings=0.0;
 for(int i=0;i<6;i++){float rr=u_resolution.y*(0.17+float(i)*0.064);rings=max(rings,1.0-smoothstep(0.3,1.1,abs(r-rr)));}
 float a=atan(q.y,q.x)+3.14159265;
 float tick=1.0-smoothstep(0.006,0.012,min(mod(a,0.10471975),0.10471975-mod(a,0.10471975)));
 tick*=step(u_resolution.y*0.352,r)*step(r,u_resolution.y*0.365);
 float grain=(hash(floor(p))-0.5)*u_grain*0.14;
 vec3 c=u_bg+u_ink*u_strength*(fine*0.045+major*0.075+u_rings*(rings*0.11+tick*0.11))+grain;
 gl_FragColor=vec4(c,1.0);
}
