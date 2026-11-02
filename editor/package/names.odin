package unreal

import "core:strings"

// The prefixes Unreal's naming conventions give the name of an asset by its
// type (SM_Rock, MI_Rock, T_Rock_D), which the assets imported from it go
// without: their kind is their type.
@(rodata)
TYPE_PREFIXES:=[?]string{
    "SM","SK","SKM","SKEL","M","MI","MIC","MF","MA","ML","MLB","MPC","T","TX","TC","RT",
    "BP","ABP","A","AS","AM","AO","BS","PA","PHYS","NS","NE","P","S","SC","SW","W","WBP",
    "LS","DT","FT","CR","IK","RTG",
}

// The name of an asset without the prefix of its type: "SM_Rock" is "Rock".
// A name that is only a prefix, or has none, stays.
asset_name :: proc(name:string) -> string {
    under:=strings.index_byte(name,'_')
    if under<=0 || under==len(name)-1 {return name}
    for prefix in TYPE_PREFIXES {
        if name[:under]==prefix {return name[under+1:]}
    }
    return name
}
