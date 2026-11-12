package unreal

// UE4 package versions where the layout of what this package reads changed.
@(private) UE4_OLDEST_LOADABLE :: 214
@(private) UE4_WORLD_LEVEL_INFO :: 224
@(private) UE4_CHUNK_ID :: 278
@(private) UE4_ARRAY_PROPERTY_INNER_TAGS :: 282
@(private) UE4_CHUNK_ID_ARRAY :: 326
@(private) UE4_ENGINE_VERSION_OBJECT :: 336
@(private) UE4_LOAD_FOR_EDITOR_GAME :: 365
@(private) UE4_SOFT_PACKAGE_REFERENCES :: 384
@(private) UE4_STRUCT_GUID_IN_PROPERTY_TAG :: 441
@(private) UE4_COMPATIBLE_ENGINE_VERSION :: 444
@(private) UE4_GATHERABLE_TEXT :: 459
@(private) UE4_COOKED_ASSETS_IN_EDITOR :: 485
@(private) UE4_INNER_ARRAY_TAG_INFO :: 500
@(private) UE4_PROPERTY_GUID_IN_PROPERTY_TAG :: 503
@(private) UE4_NAME_HASHES :: 504
@(private) UE4_PRELOAD_DEPENDENCIES :: 507
@(private) UE4_TEMPLATE_INDEX :: 508
@(private) UE4_SET_MAP_PROPERTY_TAGS :: 509
@(private) UE4_SEARCHABLE_NAMES :: 510
@(private) UE4_64BIT_EXPORT_SIZES :: 511
@(private) UE4_LOCALIZATION_ID :: 516
@(private) UE4_PACKAGE_OWNER :: 518
@(private) UE4_NON_OUTER_PACKAGE_IMPORT :: 520
@(private) UE4_LATEST :: 522

@(private)
summary_read :: proc(r:^Reader,limits:Limits) -> (s:Summary,package_name:Serialized_String) {
    if u64(len(r.bytes))>limits.source_bytes {bad(r,.Limit,"source bytes");return}
    if u32_read(r,"package signature")!=0x9e2a83c1 {bad(r,.Malformed,"package signature; expected little-endian Unreal package");return}
    raw_version:=u32_read(r,"legacy file version")
    // Newer packages pack the offset table position into the upper bits; 0xf7 is -9 saved with a zero offset.
    if raw_version==0xf7 {raw_version|=0xffffff00}
    s.legacy_version=transmute(i32)raw_version
    if s.legacy_version< -256 {
        packed_offset:=(raw_version>>8)&0x7fffff
        if raw_version>>8!=0xffffff {
            s.offset_table_offset=packed_offset
            s.legacy_version=transmute(i32)(raw_version|0xffffff00)
        }
    }
    if s.legacy_version< -9 || s.legacy_version> -3 {bad(r,.Unsupported_Version,"package file marker; expected -3 to -9");return}
    if s.legacy_version!= -4 {_=i32_read(r,"UE3 marker")}
    s.version_ue4=i32_read(r,"UE4 package version")
    if s.legacy_version<= -8 {s.version_ue5=i32_read(r,"UE5 package version")}
    s.licensee_version=i32_read(r,"licensee package version")
    if s.version_ue4==0 && s.version_ue5==0 && s.licensee_version==0 {bad(r,.Unversioned,"package has no serialization versions; mappings or native export are required");return}
    ue4:=s.version_ue4
    if ue4<UE4_OLDEST_LOADABLE || ue4>UE4_LATEST || s.version_ue5!=0 && (ue4!=UE4_LATEST || s.version_ue5<1000 || s.version_ue5>1018) || s.licensee_version!=0 {
        bad(r,.Unsupported_Version,"supported source schema is UE4 214..522 with UE5 absent, or UE4=522 with UE5 1000..1018, licensee=0")
        return
    }
    if s.version_ue5>=1016 {
        copy(s.saved_hash[:],take(r,20,"saved package hash"))
        s.total_header_size=i32_read(r,"total header size")
    }
    custom_count:=i32_read(r,"custom version count")
    if custom_count<0 || u32(custom_count)>limits.table_entries {bad(r,.Limit,"custom version count");return}
    s.custom_version_count=custom_count
    s.custom_versions_named=s.legacy_version>= -5
    start:=r.at
    for _ in 0..<custom_count {
        _=take(r,20,"custom version")
        if s.custom_versions_named {_=text_read(r,limits.text_bytes,"custom version name")}
        if r.error.code!=.None {return}
    }
    s.custom_versions={i64(start),i64(r.at-start)}
    if s.version_ue5<1016 {s.total_header_size=i32_read(r,"total header size")}
    package_name=text_read(r,limits.text_bytes,"package name")
    s.package_flags=u32_read(r,"package flags")
    if s.package_flags&0x2000!=0 {bad(r,.Unversioned,"unversioned properties require reflected schema mappings or native export");return}
    if s.package_flags&0x200!=0 {bad(r,.Cooked,"cooked packages do not retain editor source data; import the uncooked project content");return}
    editor_data:=s.package_flags&0x80000000==0
    s.name_count=i32_read(r,"name count")
    s.name_offset=i32_read(r,"name table offset")
    if s.version_ue5>=1008 {
        s.soft_path_count=i32_read(r,"soft object path count")
        s.soft_path_offset=i32_read(r,"soft object path table offset")
    }
    if editor_data && ue4>=UE4_LOCALIZATION_ID {_=text_read(r,limits.text_bytes,"localization id")}
    if ue4>=UE4_GATHERABLE_TEXT {_=take(r,8,"gatherable text table")}
    s.export_count=i32_read(r,"export count")
    s.export_offset=i32_read(r,"export table offset")
    s.import_count=i32_read(r,"import count")
    s.import_offset=i32_read(r,"import table offset")
    if s.version_ue5>=1015 {_=take(r,16,"verse cell tables")}
    if s.version_ue5>=1014 {_=take(r,4,"metadata offset")}
    _=take(r,4,"dependency offset")
    if ue4>=UE4_SOFT_PACKAGE_REFERENCES {
        s.soft_package_count=i32_read(r,"soft package reference count")
        s.soft_package_offset=i32_read(r,"soft package reference offset")
        if s.soft_package_count<0 || u32(s.soft_package_count)>limits.table_entries {bad(r,.Limit,"soft package reference count");return}
    }
    if ue4>=UE4_SEARCHABLE_NAMES {_=take(r,4,"searchable names offset")}
    _=take(r,4,"thumbnail table offset")
    if s.version_ue5>=1018 {_=take(r,8,"import type hierarchy table")}
    if s.version_ue5<1016 {copy(s.saved_hash[:16],take(r,16,"package guid"))}
    if editor_data && ue4>=UE4_PACKAGE_OWNER {
        _=take(r,16,"persistent package guid")
        if ue4<UE4_NON_OUTER_PACKAGE_IMPORT {_=take(r,16,"owner persistent guid")}
    }
    generation_count:=i32_read(r,"generation count")
    if generation_count<0 || u32(generation_count)>limits.table_entries {bad(r,.Limit,"generation count");return}
    _=take(r,int(generation_count)*8,"generations")
    if ue4>=UE4_ENGINE_VERSION_OBJECT {
        _=take(r,10,"engine version")
        _=text_read(r,limits.text_bytes,"engine branch")
    } else {
        _=take(r,4,"engine changelist")
    }
    if ue4>=UE4_COMPATIBLE_ENGINE_VERSION {
        _=take(r,10,"compatible engine version")
        _=text_read(r,limits.text_bytes,"compatible engine branch")
    }
    compression:=u32_read(r,"compression flags")
    chunk_count:=i32_read(r,"compressed chunk count")
    if compression!=0 || chunk_count!=0 {bad(r,.Compressed,"package-level compression is unsupported");return}
    _=take(r,4,"package source")
    additional_count:=i32_read(r,"additional packages count")
    if additional_count<0 || u32(additional_count)>limits.table_entries {bad(r,.Limit,"additional packages count");return}
    for _ in 0..<int(additional_count) {_=text_read(r,limits.text_bytes,"additional package")}
    if s.legacy_version> -7 && i32_read(r,"texture allocations")!=0 {bad(r,.Unsupported_Value,"package keeps texture allocations");return}
    _=take(r,4,"asset registry offset")
    s.bulk_data_start=i64_read(r,"bulk data start offset")
    if ue4>=UE4_WORLD_LEVEL_INFO {_=take(r,4,"world tile offset")}
    if ue4>=UE4_CHUNK_ID_ARRAY {
        chunk_ids:=i32_read(r,"chunk id count")
        if chunk_ids<0 || u32(chunk_ids)>limits.table_entries {bad(r,.Limit,"chunk id count");return}
        _=take(r,int(chunk_ids)*4,"chunk ids")
    } else if ue4>=UE4_CHUNK_ID {
        _=take(r,4,"chunk id")
    }
    if ue4>=UE4_PRELOAD_DEPENDENCIES {_=take(r,8,"preload dependency table")}
    if s.version_ue5>=1001 {_=take(r,4,"names referenced from export count")}
    if s.version_ue5>=1002 {_=take(r,8,"payload toc offset")}
    if s.version_ue5>=1009 {_=take(r,4,"data resource offset")}
    s.serialized_size=i64(r.at)
    if r.error.code!=.None {return}
    if i64(s.total_header_size)<i64(r.at) || i64(s.total_header_size)>i64(len(r.bytes)) {bad(r,.Malformed,"total header size");return}
    if s.offset_table_offset!=0 && u64(s.offset_table_offset)>=u64(len(r.bytes)) {bad(r,.Malformed,"package offset table offset");return}
    counts:=[3]i32{s.name_count,s.import_count,s.export_count}
    offsets:=[3]i32{s.name_offset,s.import_offset,s.export_offset}
    // Smallest entry of each table in the oldest layout.
    minimums:=[3]i64{5,28,64}
    for count,i in counts {
        if count<0 || u32(count)>limits.table_entries {bad(r,.Limit,"package table count");return}
        if count==0 {continue}
        if i64(offsets[i])<i64(r.at) || offsets[i]>s.total_header_size || i64(count)*minimums[i]>i64(s.total_header_size-offsets[i]) {
            bad(r,.Malformed,"package table range")
            return
        }
    }
    return
}
