package unreal_vfx_editor

import "core:testing"
import "plugins:vfx/runtime/effect"

// A curve of Unreal with more keys than an effect keeps is sampled at evenly
// spread times, and one that fits keeps its keys.
@(test)
unreal_curves_keep_their_keys_or_their_shape :: proc(t:^testing.T) {
    d:Dist
    for i in 0..<3 {d.times[i],d.values[i]=f32(i)*0.5,{f32(i),0,0}}
    d.key_count=3
    c:=dist_curve(d,0)
    testing.expect(t,c.times[0]==0 && c.times[1]==0.5 && c.times[2]==1 && c.values[2]==2 && c.values[7]==2)
    for i in 0..<20 {d.times[i],d.values[i]=f32(i)/19,{f32(i)/19*4,0,0}}
    d.key_count=20
    c=dist_curve(d,0)
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
    testing.expect(t,effect.particle_validate({info=&info}).message=="")
}
