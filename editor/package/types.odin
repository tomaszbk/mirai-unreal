package unreal

import "core:mem"

Error_Code :: enum u8 {
    None,
    Truncated,
    Malformed,
    Unsupported_Version,
    Unversioned,
    Cooked,
    Compressed,
    Limit,
    Out_Of_Memory,
    Invalid_Reference,
    Cyclic_Outer,
    Missing_Property_Range,
    Unsupported_Extension,
    Unsupported_Value,
}

Error :: struct {
    code:Error_Code,
    offset:i64,
    field:string,
}

Limits :: struct {
    source_bytes:u64,
    table_entries:u32,
    text_bytes:u32,
    property_count:u32,
    outer_depth:u32,
}

DEFAULT_LIMITS :: Limits{source_bytes=512<<20,table_entries=1<<20,text_bytes=16<<20,property_count=1<<18,outer_depth=256}

Span :: struct {offset,size:i64}
Name_Ref :: struct {index,number:i32}
Object_Ref :: distinct i32 // zero is null, negative imports and positive exports are one-based
Guid :: [16]u8

Custom_Version :: struct {guid:Guid,version:i32}

Summary :: struct {
    legacy_version,version_ue4,version_ue5,licensee_version:i32,
    package_flags:u32,
    stored_package_name:string, // deprecated summary field; not an object identity
    total_header_size:i32,
    name_count,name_offset:i32,
    import_count,import_offset:i32,
    export_count,export_offset:i32,
    soft_path_count,soft_path_offset:i32, // the soft object paths that properties name by index (UE5 1008 on)
    soft_package_count,soft_package_offset:i32, // the packages its properties name softly: a name each
    custom_versions:Span,
    custom_version_count:i32,
    custom_versions_named:bool, // UE4 saves before legacy version -6 name each custom version
    serialized_size:i64,
    bulk_data_start:i64, // where payloads saved at the end of the file start
    offset_table_offset:u32,
    saved_hash:[20]u8,
}

Name :: struct {
    text:string,
    source:Span,
    non_case_hash,case_hash:u16,
    owned_text:[]u8,
}

Object_Import :: struct {
    class_package,class_name:Name_Ref,
    outer:Object_Ref,
    object_name,package_name:Name_Ref,
    optional:bool,
    source:Span,
}

Object_Export :: struct {
    class,super,template,outer:Object_Ref,
    object_name:Name_Ref,
    object_flags,package_flags:u32,
    data:Span,
    script_start,script_end:i64, // relative to data.offset; absent before UE5 package version 1010
    source:Span,
    forced,not_for_client,not_for_server,inherited,not_always_loaded_for_editor_game,is_asset,generate_public_hash:bool,
}

// Input bytes stay immutable and owned by the caller until package_destroy.
Package :: struct {
    bytes:[]u8,
    source_package:string, // caller-supplied canonical mount identity
    summary:Summary,
    names:[]Name,
    imports:[]Object_Import,
    exports:[]Object_Export,
    custom_versions:[]Custom_Version,
    allocator:mem.Allocator,
    limits:Limits,
    owned_package_name:[]u8,
}

MAX_TYPE_NODES :: 16
Type_Node :: struct {name:Name_Ref,children:i32}

Property :: struct {
    name:Name_Ref,
    types:[MAX_TYPE_NODES]Type_Node,
    type_count:u8,
    array_index:i32,
    bool_value:bool,
    native,skipped:bool,
    extension_flags,override_operation:u8,
    experimental_override,experimental_external_objects:bool,
    property_guid,struct_guid:Guid,
    has_property_guid,has_struct_guid:bool,
    source,data:Span,
}

Property_List :: struct {
    items:[]Property,
    source,trailing:Span,
    serialization_control:u8,
    allocator:mem.Allocator,
}

Value_Kind :: enum u8 {Boolean,Signed,Unsigned,Real,Real_Vector,Name,Object,String,Guid}
Value :: struct {
    kind:Value_Kind,
    boolean:bool,
    signed:i64,
    unsigned:u64,
    real:f64,
    vector:[4]f64,
    vector_count:u8,
    name:Name_Ref,
    guid:Guid,
    object:Object_Ref,
    text:string,
    owned_text:[]u8,
    allocator:mem.Allocator,
}
