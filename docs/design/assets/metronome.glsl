#version 100
precision highp float;
/**
 * @resolution
 */
uniform vec2 u_resolution;
/**
 * @time
 */
uniform float u_time;
/**
 * @label BPM
 * @range 40, 240
 * @default 144.2
 */
uniform float u_bpm;
/**
 * @label Accent
 * @color
 * @default #75baff
 */
uniform vec3 u_accent;
/**
 * @label Running
 * @range 0, 1
 * @default 1
 */
uniform float u_running;
/**
 * @label Still phase in beats
 * @range 0, 2
 * @default 0
 */
uniform float u_phase;
void main(){
 vec2 p=gl_FragCoord.xy;
 float beats=u_running>0.5 ? u_time*u_bpm/60.0:u_phase;
 float x=u_resolution.x*(0.5-0.43*cos(beats*3.14159265));
 float tick=mod(p.x,u_resolution.x/8.0);
 float grid=(1.0-smoothstep(0.5,1.2,min(tick,u_resolution.x/8.0-tick)))*0.16;
 float top=step(u_resolution.y-1.0,p.y);
 float bottom=step(p.y,1.0);
 float cursor=(1.0-smoothstep(1.2,2.1,abs(p.x-x)))*step(2.0,p.y)*step(p.y,u_resolution.y-2.0);
 vec3 c=mix(vec3(0.14,0.2,0.3),u_accent,grid+0.12*(top+bottom));
 c=mix(c,u_accent,cursor);
 gl_FragColor=vec4(c,0.28+cursor*0.72+grid*0.25);
}
