package unreal

import "core:testing"

@(test)
unreal_class_defaults_use_class_identity_and_flags_instead_of_export_names :: proc(t:^testing.T) {
    exports:=[4]Object_Export{
        {},
        {class=1,object_name={0,0}},
        {class=1,object_name={1,0},object_flags=0x10},
        {class=2,object_name={2,0},object_flags=0x10},
    }
    p:=Package{exports=exports[:]}
    default,error:=class_default_object(&p,1)
    testing.expect_value(t,error.code,Error_Code.None)
    testing.expect_value(t,default,Object_Ref(3))
    p.exports[1].object_flags=0x10
    _,duplicate:=class_default_object(&p,1)
    testing.expect_value(t,duplicate.code,Error_Code.Malformed)
    _,missing:=class_default_object(&p,3)
    testing.expect_value(t,missing.code,Error_Code.Invalid_Reference)
    for invalid in ([3]Object_Ref{-1,0,5}) {
        _,invalid_error:=class_default_object(&p,invalid)
        testing.expect_value(t,invalid_error.code,Error_Code.Invalid_Reference)
    }
    _,nil_error:=class_default_object(nil,1)
    testing.expect_value(t,nil_error.code,Error_Code.Invalid_Reference)
}
