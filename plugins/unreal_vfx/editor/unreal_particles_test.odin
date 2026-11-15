package unreal_vfx_editor

import "core:testing"
import "plugins:vfx/runtime/effect"

// A curve of Unreal with more keys than an effect keeps is sampled at evenly
// spread times, and one that fits keeps its keys; the curves of several
// modules multiply, at the keys of all.
@(test)
unreal_curves_keep_their_keys_or_their_shape :: proc(t:^testing.T) {
    d:Dist
    for i in 0..<3 {d.times[i],d.values[i]=f32(i)*0.5,{f32(i),0,0}}
    d.key_count=3
    c:=life_curve({d})
    testing.expect(t,c.times[0]==0 && c.times[1]==0.5 && c.times[2]==1 && c.values[2]==2 && c.values[7]==2)
    half:=Dist{min={0.5,0.5,0.5},max={0.5,0.5,0.5},found=true}
    ramp:Dist
    ramp.times[0],ramp.times[1],ramp.values[0],ramp.values[1],ramp.key_count=0.25,0.75,{1,1,1},{3,3,3},2
    c=life_curve({d,half,ramp})
    testing.expectf(t,c.times[0]==0 && c.times[1]==0.25 && c.times[2]==0.5 && c.times[3]==0.75 && c.times[4]==1,"%v",c.times)
    testing.expectf(t,c.values[1]==0.5*0.5*1 && c.values[2]==1*0.5*2 && c.values[4]==2*0.5*3,"%v",c.values)
    for i in 0..<20 {d.times[i],d.values[i]=f32(i)/19,{f32(i)/19*4,0,0}}
    d.key_count=20
    c=life_curve({d})
    for i in 0..<effect.PARTICLE_CURVE_KEYS {
        testing.expectf(t,abs(c.values[i]-c.times[i]*4)<1e-4,"key %d of a line: %v at %v",i,c.values[i],c.times[i])
    }
    testing.expect(t,dist_at(d,2)=={4,0,0} && dist_at(d,-1)=={0,0,0})
}

// Colors of Unreal above one give their peak to the intensity of the effect.
@(test)
unreal_colors_above_one_go_to_the_intensity :: proc(t:^testing.T) {
    info:=UNREAL_PARTICLE_DEFAULTS
    colors_set(&info,{4,2,0,1},{1,1,1,2})
    testing.expect(t,info.intensity==4)
    testing.expect(t,info.colors[0]=={1,0.5,0,1} && info.colors[1]=={0.25,0.25,0.25,1})
    testing.expect(t,effect.particle_validate({info=info}).message=="")
}
