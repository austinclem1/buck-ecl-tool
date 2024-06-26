pub const Tag = enum(u8) {
    EXIT,
    GOTO,
    GOSUB,
    COMPARE,
    ADD,
    SUBTRACT,
    DIVIDE,
    MULTIPLY,
    RANDOM,
    SAVE,
    LOADCHARACTER,
    LOADMONSTER,
    SETUPMONSTERS,
    APPROACH,
    PICTURE,
    INPUTNUMBER,
    INPUTSTRING,
    PRINT,
    PRINTCLEAR,
    RETURN,
    COMPAREAND,
    MENU,
    IFEQ,
    IFNE,
    IFLT,
    IFGT,
    IFLE,
    IFGE,
    CLEARMONSTERS,
    SETTIMER,
    CHECKPARTY,
    SPACECOMBAT,
    NEWECL,
    LOADFILES,
    SKILL,
    PRINTSKILL,
    COMBAT,
    ONGOTO,
    ONGOSUB,
    TREASURE,
    ROB,
    CONTINUE,
    GETABLE,
    HMENU,
    GETYN,
    DRAWINDOW,
    DAMAGE,
    AND,
    OR,
    WHMENU,
    FINDITEM,
    PRINTRETURN,
    CLOCK,
    SAVETABLE,
    ADDNPC,
    LOADPIECES,
    PROGRAM,
    WHO,
    DELAY,
    SPELLS,
    PROTECT,
    CLEARBOX,
    DUMP,
    JOURNAL,
    DESTROY,
    ADDEP,
    ENCEXIT,
    SOUND,
    SAVECHARACTER,
    HOWFAR,
    FOR,
    ENDFOR,
    HIDEITEMS,
    SKILLDAMAGE,
    DUEL,
    STORE,
    VIEW,
    ANIMATE,
    STAIRCASE,
    HALFSTEP,
    STEPFORWARD,
    PALETTE,
    UNLOCKDOOR,
    ADDFIGURE,
    ADDCORPSE,
    ADDFIGURE2,
    ADDCORPSE2,
    UPDATEFRAME,
    REMOVEFIGURE,
    EXPLOSION,
    STEPBACK,
    HALFBACK,
    NEWREGION,
    ICONMENU,

    pub fn isConditional(tag: Tag) bool {
        return switch (tag) {
            .IFEQ, .IFNE, .IFLT, .IFGT, .IFLE, .IFGE => true,
            else => false,
        };
    }

    pub fn isFallthrough(tag: Tag) bool {
        return switch (tag) {
            .EXIT, .GOTO, .RETURN, .ENCEXIT => false,
            else => true,
        };
    }

    pub fn getArgCount(command_tag: Tag) u8 {
        return switch (command_tag) {
            .EXIT => 0x00,
            .GOTO => 0x01,
            .GOSUB => 0x01,
            .COMPARE => 0x02,
            .ADD => 0x03,
            .SUBTRACT => 0x03,
            .DIVIDE => 0x03,
            .MULTIPLY => 0x03,
            .RANDOM => 0x02,
            .SAVE => 0x02,
            .LOADCHARACTER => 0x01,
            .LOADMONSTER => 0x03,
            .SETUPMONSTERS => 0x04,
            .APPROACH => 0x00,
            .PICTURE => 0x01,
            .INPUTNUMBER => 0x02,
            .INPUTSTRING => 0x03, // NOTE: changed from 2 (this command is also not supported in genesis)
            .PRINT => 0x01,
            .PRINTCLEAR => 0x01,
            .RETURN => 0x00,
            .COMPAREAND => 0x04,
            .MENU => 0x00,
            .IFEQ => 0x00,
            .IFNE => 0x00,
            .IFLT => 0x00,
            .IFGT => 0x00,
            .IFLE => 0x00,
            .IFGE => 0x00,
            .CLEARMONSTERS => 0x00,
            .SETTIMER => 0x02,
            .CHECKPARTY => 0x06,
            .SPACECOMBAT => 0x04, // NOTE: changed from 2
            .NEWECL => 0x01,
            .LOADFILES => 0x03,
            .SKILL => 0x03,
            .PRINTSKILL => 0x03,
            .COMBAT => 0x00,
            .ONGOTO => 0x00,
            .ONGOSUB => 0x02,
            .TREASURE => 0x00,
            .ROB => 0x03,
            .CONTINUE => 0x00,
            .GETABLE => 0x03,
            .HMENU => 0x00,
            .GETYN => 0x00,
            .DRAWINDOW => 0x00,
            .DAMAGE => 0x05,
            .AND => 0x03,
            .OR => 0x03,
            .WHMENU => 0x00,
            .FINDITEM => 0x01,
            .PRINTRETURN => 0x00,
            .CLOCK => 0x01,
            .SAVETABLE => 0x03,
            .ADDNPC => 0x02, // NOTE: changed from 1
            .LOADPIECES => 0x01,
            .PROGRAM => 0x01,
            .WHO => 0x01,
            .DELAY => 0x00,
            .SPELLS => 0x03,
            .PROTECT => 0x01,
            .CLEARBOX => 0x00,
            .DUMP => 0x00,
            .JOURNAL => 0x02,
            .DESTROY => 0x02,
            .ADDEP => 0x02,
            .ENCEXIT => 0x00,
            .SOUND => 0x01,
            .SAVECHARACTER => 0x00,
            .HOWFAR => 0x02,
            .FOR => 0x02,
            .ENDFOR => 0x00,
            .HIDEITEMS => 0x01,
            .SKILLDAMAGE => 0x06,
            .DUEL => 0x00,
            .STORE => 0x01,
            .VIEW => 0x02,
            .ANIMATE => 0x00,
            .STAIRCASE => 0x00,
            .HALFSTEP => 0x00,
            .STEPFORWARD => 0x00,
            .PALETTE => 0x01,
            .UNLOCKDOOR => 0x00,
            .ADDFIGURE => 0x04,
            .ADDCORPSE => 0x03,
            .ADDFIGURE2 => 0x04,
            .ADDCORPSE2 => 0x03,
            .UPDATEFRAME => 0x01,
            .REMOVEFIGURE => 0x00,
            .EXPLOSION => 0x01,
            .STEPBACK => 0x00,
            .HALFBACK => 0x00,
            .NEWREGION => 0x00,
            .ICONMENU => 0x00,
        };
    }
};
