package inspect

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import fixture "project:plugins/unreal/editor/fixture/files"

// What the caller keeps in its temporary allocator, as unreal.inspect keeps
// its report, outlives the packages of a folder.
@(test)
the_report_of_a_folder_outlives_its_packages :: proc(t:^testing.T) {
    folder:=".mirai/tmp/unreal-inspect-test"
    _=os.make_directory_all(folder)
    defer os.remove_all(folder)
    for name in ([]string{"T_First","T_Second"}) {
        w:=fixture.writer_make({package_name=fmt.tprintf("/Game/%s",name)})
        data:=fixture.bytes_make()
        fixture.none(&data,&w)
        fixture.put_u32(&data,0)
        fixture.export_add(&w,{class=fixture.engine_class(&w,"Texture2D"),name=name,data=data.data[:]})
        _=os.write_entire_file(fmt.tprintf("%s/%s.uasset",folder,name),fixture.package_bytes(&w))
    }
    report:=strings.builder_make(context.temp_allocator)
    testing.expect(t,run(strings.to_writer(&report),{target=strings.clone(folder,context.temp_allocator),mode=.Summary}))
    text:=strings.to_string(report)
    for name in ([]string{"T_First.uasset","T_Second.uasset","[1] T_First","[1] T_Second"}) {
        testing.expectf(t,strings.contains(text,name),"the report names %s:\n%s",name,text)
    }
}
