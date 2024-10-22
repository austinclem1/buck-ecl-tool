# Buck Rogers ECL Script Extractor and Assembler

Have you ever wanted to view and edit the scripting bytecode used in Strategic
Simulations' 1991 Sega port of CRPG "Buck Rogers: Countdown to Doomsday?" ...No?

This is a command line tool that can decompress and disassemble the scripts for
all the game levels in your legally obtained rom 👀. It will output each level
as a separate file in a text format that reads top to bottom, resembling some
form of assembly complete with labels GOTOs. From there you can edit the files
and use this tool to assemble, compress, then patch your rom with the updated
level data. It also includes a command that will patch a bug in the original
game regarding a nasty edge-case gone wrong with the way one of the original
levels was compressed.

## Utility Subcommands

### `extract-all --rom [YOUR ROM FILE] --out [DESTINATION DIR]`
This will generate a text file for every level in the rom in the specified
output directory. **NOTE:** If you get an error regarding an invalid code while
decompressing level id 97, you probably need to run the `fix-mariposa` command
first, because of a compression bug in the original game data for that level.

### `patch-rom --rom [YOUR ROM FILE] --ecl [YOUR UPDATED ECL FILE] --dest-level-id [LEVEL ID TO PATCH] --out [PATH TO PUT PATCHED ROM]`
This command will assemble and compress the given ecl text format file, then
patch the specified level in the rom with that data. You'll get an error if the
resulting data is too large to fit in the space taken up by the original data.
The error messages regarding parsing the text format are pretty lacking
unfortunately.

### `fix-mariposa --rom [YOUR ROM FILE]`
This will apply a fix to the compressed text data for level id 97 (Mariposa)
that caused the decompression code to run on endlessly decompressing whatever
random data happened to be past the actual level data.

## Text Format

The text format is very ad hoc and has three main parts:

### Header
  A list of five labels, the exact purpose of which still need to be deciphered.
  As far as I can tell this is what each header label is used for:
  1. Execution starts at this label right after the player begins moving on
    the map.
  2. Execution starts here as the player character finishes taking a step on
    the map.
  3. Unused? This and the below point to a command block with a single EXIT
     or ENCEXIT command, essentially doing nothing in every example I could
     find.
  4. Unused?
  5. This runs upon starting the level.

### Variable Declarations

After the header definition but before any level commands you may declare
variables like so:

```
var my_byte_var: byte @ 0x1234
var my_word_var: word @ 0x5678
var my_dword_var: dword @ 0x1000
var my_ptr_var: pointer @ 0x2000
```

Each of these declare a variable of the specified size/type at the specified
offset into the Genesis RAM.
So in the example above, my_byte_var can be used to refer to a single byte at
address 0xff1234 (Genesis RAM begins at 0xff0000 and goes as high as 0xffffff.)
The type `pointer` could probably be more accurately called `address`, also it
doesn't really exist *at* the specified location as much as it is an alias for
that memory location (with no size associated with the data at that location).

### Command Blocks

This is where the actual script commands go. They are written as a series of
labels, each containing one or more commands. Each command starts with a
command keyword, and is followed by zero or more arguments. Arguments can be
one of the following:
- integer literal i.e. `5`
- string literal i.e. `"hello world"`
- the name of a label i.e. `entry_point` usually used in commands that branch,
like GOTO, GOSUB, ONGOTO, and ONGOSUB
- byte, word, or dword sized var identifier i.e. `my_byte_var`
- pointer var followed by an offset in square brackets, then suffixed with a
character specifying what size of data to read or write at the resulting
address. Valid suffixes are `b` for byte, `w` for word (2 bytes), or `d` for
dword (4 bytes) i.e. `my_ptr_var[2]w` This refers to a word sized value located
at the address of my_ptr_var + offset 2. Depending on which command it's used
with, we may be reading a word value *from* that location or writing a word
value *to* that location.

**Note:** the type `pointer` is hardly used, at least in the SEGA version of
the game. In general, you can use a variable of any other type as an argument
to a command that's expecting an address. i.e. if I have a variable called
`my_byte_var` of type `byte`, I can use it like so:
```
ADD my_byte_var 1 my_byte_var
```
The ADD commands adds the values of the first two arguments together, then
stores the result in the location of the third argument. So here `my_byte_var`
is being used as a value (in the first argument) and as an address (in the third
argument)

## Example Script
```
header:
  start_step
  end_step
  my_do_nothing_label
  my_do_nothing_label
  entry_point

var scratch_space: pointer @ 0x97f6
var hello_count: byte @ 0x9e6f

my_do_nothing_label:
  EXIT
start_step:
  EXIT
end_step:
  EXIT
entry_point:
  SAVE 1234 scratch_space[2]w # store 1234 as a word-size value at the address of scratch_space + 2
  SAVE 0 hello_count # store value 0 at location of hello_count variable
loop:
  COMPARE hello_count 5
  IFGE # only execute the following command if the previous comparison was greater than or equal
  EXIT # finish executing commands, the game still continues
  PRINTCLEAR "hello!"
  CONTINUE # wait for player to press a button
  ADD 1 hello_count hello_count # increment hello_count before looping
  GOTO loop
```
The above script prints "hello!" 5 times, waiting for the player to press a
button between each iteration.

## Script Commands
I got the names of all the commands as well as their argument counts from some
debugging code that was left in the original game. It would take some
experimentation to figure what each argument represents for each command but
some of them are pretty self explanatory. Certain commands aren't supported in
the SEGA version of the game.

**Work In Progress**
The following commands show my best guess as to what each positional argument
represents. When it's unknown, or I haven't gotten around to it yet, I just
wrote the argument count.

### Branching
- GOTO *label*
- GOSUB *label*
- ONGOTO *label_index* *N* *[... N labels]*
- ONGOSUB *label_index* *N* *[... N labels]*

### Arithmetic
- ADD *op1* *op2* *dest*
- SUBTRACT *op1* *op2* *dest*
- DIVIDE *op1* *op2* *dest*
- MULTIPLY *op1* *op2* *dest*
- AND *op1* *op2* *dest*
- OR *op1* *op2* *dest*

### Conditionals
- COMPARE *op1* *op2*
- IFEQ
- IFNE
- IFLT
- IFGT
- IFLE
- IFGE

### Uncategorized
- EXIT
- RANDOM 2
- SAVE *value* *dest*
- LOADCHARACTER 1
- LOADMONSTER 3
- SETUPMONSTERS 4
- APPROACH
- PICTURE *pic_num*
- INPUTNUMBER 2
- PRINT *string*
- PRINTCLEAR *string*
- RETURN
- COMPAREAND 4
- CLEARMONSTERS
- SPACECOMBAT 4
- NEWECL *ecl_num_to_load*
- LOADFILES 3
- SKILL 3
- PRINTSKILL 3
- COMBAT
- TREASURE *credits* *N* *[...N item ids]*
- CONTINUE
- GETABLE 3
- HMENU *choice_dest* *N* *[...N choice strings]*
- WHMENU *choice_dest* *N* *[...N choice strings]*
- GETYN
- DRAWINDOW
- DAMAGE 5
- FINDITEM 1
- PRINTRETURN
- ADDNPC 2
- LOADPIECES 1
- PROGRAM 1
- WHO 1
- DELAY
- CLEARBOX
- DUMP
- DESTROY 2
- ADDEP 2
- ENCEXIT
- SOUND 1
- SAVECHARACTER
- HOWFAR 2
- FOR *start_i* *stop1_i*
- ENDFOR
- HIDEITEMS 1
- SKILLDAMAGE 6
- DUEL
- STORE 1
- VIEW 2
- ANIMATE
- STAIRCASE
- HALFSTEP
- STEPFORWARD
- PALETTE 1
- UNLOCKDOOR
- ADDFIGURE 4
- ADDCORPSE 3
- ADDFIGURE2 4
- ADDCORPSE2 3
- UPDATEFRAME 1
- REMOVEFIGURE
- EXPLOSION 1
- STEPBACK
- HALFBACK
- NEWREGION *unknown* *N* *[...Nx4 args]*
- JOURNAL 2
- ICONMENU *choice_dest* *N* *[...N choice icon ids]*

### Not Implemented for SEGA
- INPUTSTRING 3
- MENU
- SETTIMER 2
- CHECKPARTY 6
- ROB 3
- CLOCK 1
- SAVETABLE 3
- SPELLS 3
- PROTECT 1
