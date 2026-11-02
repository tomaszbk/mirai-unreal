package unreal

import "core:testing"

@(test)
unreal_graph_pins_keep_their_values_links_and_bits :: proc(t:^testing.T) {
    w:=Fixture_Writer{bytes=make([]u8,512,context.temp_allocator)}
    text_none :: proc(w:^Fixture_Writer) {put_u32(w,0);w.bytes[w.at]=0xff;w.at+=1;put_u32(w,0)}
    put_u32(&w,2)
    put_u32(&w,1)
    put_u32(&w,0)
    w.at+=40
    put_name(&w,8)
    text_none(&w)
    put_u32(&w,0)
    w.bytes[w.at]=0;w.at+=1
    put_name(&w,4);put_name(&w,0);put_u32(&w,transmute(u32)i32(-2))
    w.bytes[w.at]=0;w.at+=1
    w.at+=8
    w.at+=4;put_name(&w,0);w.at+=24
    put_text(&w,"NewEnumerator2")
    put_text(&w,"NewEnumerator0")
    put_u32(&w,0)
    text_none(&w)
    put_u32(&w,1);put_u32(&w,0);w.at+=20
    put_u32(&w,0)
    put_u32(&w,1);put_u32(&w,1)
    w.bytes[w.at]=7;w.at+=16
    put_u32(&w,GRAPH_PIN_NOT_CONNECTABLE)
    p,error:=package_open(fixture_package(1018,tail=w.bytes[:w.at]),source_package="/Game/Fixture")
    if !testing.expect_value(t,error.code,Error_Code.None) {return}
    defer package_destroy(&p)
    pins,pins_error:=graph_node_pins(&p,0,context.temp_allocator)
    if !testing.expect_value(t,pins_error.code,Error_Code.None) {return}
    if !testing.expect_value(t,len(pins),1) {return}
    pin:=pins[0]
    testing.expect_value(t,name_plain(&p,pin.name),"Title")
    testing.expect_value(t,name_plain(&p,pin.category),"Class")
    testing.expect(t,pin.input,"direction 0 is an input")
    testing.expect_value(t,pin.sub_object,Object_Ref(-2))
    testing.expect_value(t,pin.default_value,"NewEnumerator2")
    testing.expect_value(t,pin.links,1)
    testing.expect(t,pin.persistent,"a nonzero guid is persistent")
    testing.expect_value(t,pin.bits,GRAPH_PIN_NOT_CONNECTABLE)
    truncated,_:=package_open(fixture_package(1018,tail=w.bytes[:w.at-2]),source_package="/Game/Fixture")
    defer package_destroy(&truncated)
    _,truncated_error:=graph_node_pins(&truncated,0,context.temp_allocator)
    testing.expect(t,truncated_error.code!=.None,"a cut pin is an error, not a value")
}
