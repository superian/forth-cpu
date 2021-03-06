( This program is written in a pseudo Forth like language, it is not
Forth and does not behave like it, it just looks like it. This should
be thought of as assembly code and not Forth.

A lot of the code has been taken verbatim from "The Zen of eForth by
C. H. Ting". Some routines have been adapted from the j1eforth implementation
available at https://github.com/samawati/j1eforth.

For a grammar of the language look into the file "h2.c", or "readme.md".

Execution begins at a label called "start".

A problem with this Forth is that is uses a singe block buffer, which can cause
problems when using the block word set from within blocks. The main reason for
this is due to the limited space on the device.

Forth To Do:
* Add do...loop, case statements, put them in block storage
* Implement many of the lessons learned whilst making the 
'embed' Forth interpreter <https://github.com/howerj/embed>, which
cuts down on the interpreter size, and adds more functionality. )

( ======================== System Constants ================= )

constant cell 2 hidden

( The first 8 cells [16 bytes] of memory contain the entry point and interrupt
service routine call locations, we can set the instruction to be run [such as
a jump or a call] by setting the label to it with the ".set" directive. Later
in the program the entry point, the first location in memory, is set to the
start label )
entry:             .allocate cell ( Entry point - not an interrupt )
isrRxFifoNotEmpty: .allocate cell ( UART RX FIFO not empty )
isrRxFifoFull:     .allocate cell ( UART RX FIFO full )
isrTxFifoNotEmpty: .allocate cell ( UART TX FIFO not empty )
isrTxFifoFull:     .allocate cell ( UART TX FIFO full )
isrKbdNew:         .allocate cell ( New PS/2 Keyboard character )
isrTimer:          .allocate cell ( Timer interrupt )
isrDPadButton:     .allocate cell ( Any D-Pad Button Changed state )

.mode 3   ( Turn word header compilation and optimization on )
.built-in ( Add the built in words to the dictionary )

constant =exit         $601c hidden ( op code for exit )
constant =invert       $6600 hidden ( op code for invert )
constant =>r           $6147 hidden ( op code for >r )
constant =bl           32    hidden ( blank, or space )
constant =cr           13    hidden ( carriage return )
constant =lf           10    hidden ( line feed )
constant =bs           8     hidden ( back space )
constant =escape       27    hidden ( escape character )

constant c/l           64    hidden ( characters per line in a block )
constant l/b           16    hidden ( lines in a block )

constant dump-width    16    hidden ( number of columns for 'dump' )
constant tib-length    80    hidden ( size of terminal input buffer )
constant pad-length    80    hidden ( pad area begins HERE + pad-length )
constant word-length   31    hidden ( maximum length of a word )

( Outputs: $6000 - $7FFF )
constant oUart         $4000 hidden ( UART TX/RX Control register )
constant oVT100        $4002 hidden ( LEDs )
constant oTimerCtrl    $4004 hidden ( Timer control register )
constant oLeds         $4006 hidden ( VGA X/Y Cursor position )
constant oMemDout      $4008 hidden ( Memory output for writes )
constant oMemControl   $400A hidden ( Memory control and high address bits )
constant oMemAddrLow   $400C hidden ( Lower memory address bits )
constant o7SegLED      $400E hidden ( 4x7 Segment display )
constant oIrcMask      $4010 hidden ( Interrupt Mask )

( Inputs: $6000 - $7FFF )
constant iUart         $4000 hidden ( Matching registers for iUart )
constant iVT100        $4002 hidden ( Switch control [on/off] )
constant iTimerDin     $4004 hidden ( Current timer value )
constant iSwitches     $4006 hidden ( VGA text output, currently broken )
constant iMemDin       $4008 hidden ( Memory input for reads )

( ======================== System Constants ================= )

( ======================== System Variables ================= )

( Execution vectors for changing the behaviour of the program,
they are set at the end of this file )
location _key?      0  ( -- c -1 | 0 : new character available? )
location _emit      0  ( c -- : emit character )
location _expect    0  ( "accept" vector )
location _tap       0  ( "tap" vector, for terminal handling )
location _echo      0  ( c -- : emit character )
location _prompt    0  ( -- : display prompt )
location _boot      0  ( -- : execute program at startup )
location _bload     0  ( a u k -- f : load block )
location _bsave     0  ( a u k -- f : save block )
location _binvalid  0  ( k -- k : throws error if k invalid )
location _message   0  ( n -- : display an error message )
location last-def   0  ( last, possibly unlinked, word definition )
location flash-voc  0  ( flash and memory word set )
location cp         0  ( Dictionary Pointer: Set at end of file )
location csp        0  ( current data stack pointer - for error checking )
location _id        0  ( used for source id )
location rendezvous 0  ( saved cp and pwd )
.allocate cell
location seed       1  ( seed used for the PRNG )
location handler    0  ( current handler for throw/catch )
variable >in        0  ( Hold character pointer when parsing input )
variable state      0  ( compiler state variable )
variable hld        0  ( Pointer into hold area for numeric output )
variable base       10 ( Current output radix )
variable span       0  ( Hold character count received by expect   )
variable loaded     0  ( Used by boot block to indicate it has been loaded  )
variable border    -1  ( Put border around block begin displayed with 'list' )
constant #vocs            8 hidden ( number of vocabularies in allowed )
variable forth-wordlist   0 ( set at the end near the end of the file )
location context          0 ( holds current context for vocabulary search order )
.allocate 14                ( ... space for context )
location #tib             0 ( Current count of terminal input buffer    )
location tib-buf          0 ( ... and address )
.set tib-buf $pc            ( set tib-buf to current dictionary location )
.allocate tib-length        ( allocate enough for the terminal input buffer )
.allocate cell              ( plus one extra cell for safety )
constant block-invalid   -1 hidden ( block invalid number )
constant b/buf 1024 ( size of a block )
variable blk             -1 ( current blk loaded )
location block-dirty      0 ( -1 if loaded block buffer is modified )
location block-buffer     0 ( block buffer starts here )
.allocate b/buf

location _blockop         0             ( used in 'mblock' )
location bcount           0             ( instruction counter used in 'see' )
location _test            0             ( used in skip/test )
location .s-string        " <sp"        ( used by .s )
location see.unknown      "(no-name)"   ( used by 'see' for calls to anonymous words )
location see.lit          "LIT"         ( decompilation -> literal )
location see.alu          "ALU"         ( decompilation -> ALU operation )
location see.call         "CAL"         ( decompilation -> Call )
location see.branch       "BRN"         ( decompilation -> Branch )
location see.0branch      "BRZ"         ( decompilation -> 0 Branch )
location see.immediate    " immediate " ( used by "see", for immediate words )
location see.inline       " inline "    ( used by "see", for inline words )
location OK               "ok"          ( used by "prompt" )
location redefined        " redefined"  ( used by ":" when a word has been redefined )
location hi-string        "eFORTH V"    ( used by "hi" )
location loading-string   "loading..."  ( used in start up routine )
location failed           "failed"      ( used in start up routine )

( ======================== System Variables ================= )

( ======================== Forth Kernel ===================== )

: [-1] -1 ; hidden         ( -- -1 : space saving measure, push -1 onto stack )
: 0x8000 $8000 ; hidden    ( -- $8000 : space saving measure, push $8000 onto stack )
: ! store drop ;           ( n a -- : store a value 'n' at location 'a'  )
: 256* 8 lshift ; hidden   ( u -- u : shift left by 8, or multiple by 256 )
: 256/ 8 rshift ; hidden   ( u -- u : shift right by 8, or divide by 256 )
: 1+ 1 + ;                 ( n -- n : increment a value  )
: negate invert 1 + ;      ( n -- n : negate a number )
: - invert 1 + + ;         ( n1 n2 -- n : subtract n1 from n2 )
: 2/ 1 rshift ;            ( n -- n : divide by 2 NB. This isn't actually correct, just useful, "1 arshift" would be acceptable )
: 2* 1 lshift ;            ( n -- n : multiply by 2 )
: cell- cell - ;           ( a -- a : adjust address to previous cell )
: cell+ cell + ;           ( a -- a : move address forward to next cell )
: cells 2* ;               ( n -- n : convert number of cells to number to increment address by )
: ?dup dup if dup exit then ;   ( n -- 0 | n n : duplicate value if it is not zero )
: >  swap < ;              ( n1 n2 -- f : signed greater than, n1 > n2 )
: u> swap u< ;             ( u1 u2 -- f : unsigned greater than, u1 > u2 )
: u>= u< invert ;          ( u1 u2 -- f : )
: <> = invert ;            ( n n -- f : not equal )
: 0<> 0= invert ;          ( n n -- f : not equal  to zero )
: 0> 0 > ;                 ( n -- f : greater than zero? )
: 0< 0 < ;                 ( n -- f : less than zero? )
: 2dup over over ;         ( n1 n2 -- n1 n2 n1 n2 )
: 2drop drop drop ;        ( n n -- )
: tuck swap over ;         ( n1 n2 -- n2 n1 n2 )
: +! tuck @ + swap ! ;     ( n a -- : increment value at address by 'n' )
: 1+!  1 swap +! ;         ( a -- : increment value at address by 1 )
: 1-! [-1] swap +! ; hidden  ( a -- : decrement value at address by 1 )
: execute >r ;             ( cfa -- : execute a function )
: c@ dup ( -2 and ) @ swap 1 and if 8 rshift exit else $ff and exit then ; ( b -- c )
: c!                       ( c b -- )
	swap $ff and dup 8 lshift or swap
	swap over dup ( -2 and ) @ swap 1 and 0 = $ff xor
	>r over xor r> and xor swap ( -2 and ) store drop ;
: c, cp @ c! cp 1+! ;    ( c -- : store 'c' at next available location in the dictionary )
: 40ns begin dup while 1- repeat drop ; hidden ( n -- : wait for 'n'*40ns + 30us )
: ms for 25000 40ns next ; ( n -- : wait for 'n' milliseconds )
: doNext r> r> ?dup if 1- >r @ >r exit then cell+ >r ; hidden

: uart? ( a1 a2 -- c -1 | 0 : generic uart input using registers 'a1' and 'a2'  )
	swap >r dup >r
	@ $0100 and 0=
	if
		$0400 r> ! r> @ $ff and [-1]
	else
		rdrop rdrop 0
	then ; hidden

: rx?  oUart iUart uart? ; hidden ( -- c -1 | 0 : read in a character of input from UART )
: ps2? oVT100 iVT100 uart? ; hidden ( -- c -1 | 0 : PS/2 version of rx? )

: uart! ( c a1 a2 -- : write to a UART, specified with registers a1, a2 )
	>r >r
	begin r@ @ $1000 and 0= until rdrop ( Wait until TX FIFO is not full )
	$2000 or r> ! ; hidden

: tx!  oUart iUart uart! ; hidden
: vga! oVT100 iVT100 uart! ; hidden ( n a -- : output character to VT100 display )

: um+ ( w w -- w carry )
	over over + >r
	r@ 0 < invert >r
	over over and
	0 < r> or >r
	or 0 < r> and invert 1 +
	r> swap ;

: rp! ( n -- , R: ??? -- ??? : set the return stack pointer )
	r> swap begin dup rp@ = 0= while rdrop repeat drop >r ; hidden

: rpick ( n -- u, R: un ... u0 )
	rdrop
	dup
	begin dup while rdrop 1- repeat drop r@ swap
	begin dup while rup   1- repeat drop
	rup ;

( With the built in words defined in the assembler, and the words
defined so far, all of the primitive words needed by eForth should
be available. "doList" and "doLit" do not need to be implemented as
they can implemented in terms of instructions )

( ======================== Forth Kernel ===================== )

( ======================== Word Set ========================= )

: 2! ( d a -- ) tuck ! cell+ ! ;          ( n n a -- )
: 2@ ( a -- d ) dup cell+ @ swap @ ;      ( a -- n n )
: here cp @ ;                             ( -- a )
: source #tib 2@ ;                        ( -- a u )
: source-id _id @ ;                       ( -- 0 | -1 )
: pad here pad-length + ;                 ( -- a )
: @execute @ ?dup if >r then ;            ( cfa -- )
: 3drop drop 2drop ; hidden               ( n n n -- )
: bl =bl ;                                ( -- c )
: within over - >r - r> u< ;              ( u lo hi -- f )
: dnegate invert >r invert 1 um+ r> + ;   ( d -- d )
: abs dup 0< if negate exit then ;        ( n -- u )
: count  dup 1+ swap c@ ;                 ( cs -- b u )
: rot >r swap r> swap ;                   ( n1 n2 n3 -- n2 n3 n1 )
: -rot swap >r swap r> ;                  ( n1 n2 n3 -- n3 n1 n2 )
: min over over < if drop exit else nip exit then ; ( n n -- n )
: max over over > if drop exit else nip exit then ; ( n n -- n )
: >char $7f and dup 127 =bl within if drop [char] _ then ; ( c -- c )
: tib #tib cell+ @ ; hidden               ( -- a )
: echo _echo @execute ; hidden            ( c -- )
: key? _key? @execute ;                   ( -- c -1 | 0 )
: key begin key? until ;                  ( -- c )
: allot cp +! ;                           ( u -- )
: /string over min rot over + -rot - ;    ( b u1 u2 -- b u : advance a string u2 characters )
: last context @ @ ;                      ( -- pwd )
: emit _emit @execute ;                   ( c -- : write out a char )
: toggle over @ xor swap ! ; hidden       ( a u -- : xor value at addr with u )
: cr =cr emit =lf emit ;                  ( -- )
: space =bl emit ;                        ( -- )
: pick ?dup if swap >r 1- pick r> swap exit then dup ; ( @bug does not work for high stack depths - mashes the return stack )
: ndrop for aft drop then next ; hidden   ( n1 ... nu u -- )
: type begin dup while swap count emit swap 1- repeat 2drop ; ( b u -- : print a string )
: $type begin dup while swap count >char emit swap 1- repeat 2drop ; hidden ( b u -- : print a string )
: print count type ; hidden               ( b -- )
: nuf? ( -- f ) key =cr = ;  ( -- f : true if 'cr' pressed, blocking )
: decimal? 48 58 within ; hidden            ( c -- f : decimal char? )
: lowercase? [char] a [char] { within ; hidden  ( c -- f : is character lower case? )
: uppercase? [char] A [char] [ within ; hidden  ( c -- f : is character upper case? )
\ : >upper dup lowercase? if =bl xor then ; ( c -- c : convert to upper case )
: >lower dup uppercase? if =bl xor exit then ; hidden ( c -- c : convert to lower case )
: nchars swap 0 max for aft dup emit then next drop ; hidden ( +n c -- : emit c n times  )
: spaces =bl nchars ;                     ( +n -- )
: cmove for aft >r dup c@ r@ c! 1+ r> 1+ then next 2drop ; ( b b u -- )
: fill swap for swap aft 2dup c! 1+ then next 2drop ; ( b u c -- )
: substitute dup @ >r ! r> ; hidden ( u a -- u : substitute value at address )
: switch 2dup @ >r @ swap ! r> swap ! ; hidden ( a a -- : swap contents )
: aligned dup 1 and if 1+ exit then ;          ( b -- a )
: align cp @ aligned cp ! ;               ( -- )

: catch  ( xt -- exception# | 0 : return addr on stack )
	sp@ >r        ( xt : save data stack depth )
	handler @ >r  ( xt : and previous handler )
	rp@ handler ! ( xt : set current handler )
	execute       (      execute returns if no throw )
	r> handler !  (      restore previous handler )
	r> drop       (      discard saved stack ptr )
	0 ;           ( 0  : normal completion )

: throw  ( ??? exception# -- ??? exception# )
	?dup if ( exc# \ 0 throw is no-op )
		handler @ rp! ( exc# : restore prev return stack )
		r> handler !  ( exc# : restore prev handler )
		r> swap >r    ( saved-sp : exc# on return stack )
		sp@ swap - ndrop r>   ( exc# : restore stack )
		( return to the caller of catch because return )
		( stack is restored to the state that existed )
		( when catch began execution )
	then ;

: -throw negate throw ; hidden ( space saving measure )

( By making all the Forth primitives call '?depth' it should be possible
to get quite good coverage for stack checking, if not there is only a few
choice words that need depth checking to get quite a large coverage )
: ?depth dup 0= if drop exit then sp@ 1- u> if 4 -throw exit then ; hidden ( u -- )
: 1depth 1 ?depth ; hidden
\ : 2depth 2 ?depth ; hidden
\ : 3depth 3 ?depth ; hidden

: um/mod ( ud u -- ur uq )
	?dup 0= if 10 -throw exit then
	2dup u<
	if negate 15
		for >r dup um+ >r >r dup um+ r> + dup
			r> r@ swap >r um+ r> or
			if >r drop 1 + r> else drop then r>
		next
		drop swap exit
	then drop 2drop  [-1] dup ;

: m/mod ( d n -- r q ) \ floored division
	dup 0< dup >r
	if
		negate >r dnegate r>
	then
	>r dup 0< if r@ + then r> um/mod r>
	if swap negate swap exit then ;

: um* ( u u -- ud )
	0 swap ( u1 0 u2 ) 15
	for dup um+ >r >r dup um+ r> + r>
		if >r over um+ r> + then
	next rot drop ;

: /mod  over 0< swap m/mod ; ( n n -- r q )
: mod  /mod drop ;           ( n n -- r )
: /    /mod nip ;            ( n n -- q )
: *    um* drop ;            ( n n -- n )
: decimal 10 base ! ;                       ( -- )
: hex     16 base ! ;                       ( -- )
: radix base @ dup 2 - 34 u> if hex 40 -throw exit then ; hidden
: digit  9 over < 7 and + 48 + ; hidden      ( u -- c )
: extract  0 swap um/mod swap ; hidden       ( n base -- n c )
: ?hold hld @ cp @ u< if 17 -throw exit then ; hidden ( -- )
: hold  hld @ 1- dup hld ! ?hold c! ;        ( c -- )
: sign  0< if [char] - hold then ;           ( n -- )
: #>  drop hld @ pad over - ;                ( w -- b u )
: #  1depth radix extract digit hold ;       ( u -- u )
: #s begin # dup while repeat ;              ( u -- 0 )
: <#  pad hld ! ;                            ( -- )
: str dup >r abs <# #s r> sign #> ; hidden   ( n -- b u : convert a signed integer to a numeric string )
\ :  .r >r str r> over - spaces type ;       ( n n : print n, right justified by +n )
: u.r >r <# #s #> r> over - spaces type ;    ( u +n -- : print u right justified by +n)
: u.  <# #s #> space type ;                  ( u -- : print unsigned number )
:  .  radix 10 xor if u. exit then str space type ; ( n -- print space, signed number )
: ? @ . ;                                    ( a -- : display the contents in a memory cell )

: pack$ ( b u a -- a ) \ null fill
	aligned dup >r over
	dup 0 cell um/mod ( use -2 and instead of um/mod? ) drop
	- over +  0 swap !  2dup c!  1+ swap cmove  r> ;

: ^h ( bot eot cur c -- bot eot cur )
	>r over r@ < dup
	if
		=bs dup echo =bl echo echo
	then r> + ; hidden

: tap dup echo over c! 1+ ; hidden ( bot eot cur c -- bot eot cur )

: ktap ( bot eot cur c -- bot eot cur )
	dup =cr xor
	if =bs xor
		if =bl tap else ^h then
		exit
	then drop nip dup ; hidden

: accept ( b u -- b u )
	over + over
	begin
		2dup xor
	while
		key  dup =bl - 95 u<
		if tap else _tap @execute then
	repeat drop over - ;

: expect ( b u -- ) _expect @execute span ! drop ;
: query tib tib-length _expect @execute #tib !  drop 0 >in ! ; ( -- )

: =string ( a1 u2 a1 u2 -- f : string equality )
	>r swap r> ( a1 a2 u1 u2 )
	over xor if 3drop  0 exit then
	for ( a1 a2 )
		aft
			count >r swap count r> xor
			if 2drop rdrop 0 exit then
		then
	next 2drop [-1] ;

: address $3fff and ; hidden ( a -- a : mask off address bits )
: nfa address cell+ ; hidden ( pwd -- nfa : move to name field address)
: cfa nfa dup count nip + cell + $fffe and ; hidden ( pwd -- cfa : move to code field address )
: .id nfa print ; hidden ( pwd -- : print out a word )

: logical 0= 0= ; hidden ( n -- f )
: immediate? @ $4000 and logical ; hidden ( pwd -- f : is immediate? )
: inline?    @ 0x8000 and logical ; hidden ( pwd -- f : is inline? )

: search ( a a -- pwd 1 | pwd -1 | a 0 : find a word in the dictionary )
	swap >r
	begin
		dup
	while
		dup nfa count r@ count =string
		if ( found! )
			dup immediate? if 1 else [-1] then
			rdrop exit
		then
		@ address
	repeat
	drop r> 0 ; hidden

: find ( a -- pwd 1 | pwd -1 | a 0 : find a word in the dictionary )
	>r
	context
	begin
		dup @
	while
		dup @ @ r@ swap search ?dup if rot rdrop drop exit else drop then
		cell+
	repeat drop r> 0 ;

: numeric? ( char -- n|-1 : convert character in 0-9 a-z range to number )
	>lower
	dup lowercase? if 87 - exit then ( 97 = 'a', +10 as 'a' == 10 )
	dup decimal?   if 48 - exit then ( 48 = '0' )
	drop [-1] ; hidden

: digit? >lower numeric? base @ u< ; hidden ( c -- f : is char a digit given base )

: do-number ( n b u -- n b u : convert string )
	begin
		( get next character )
		2dup >r >r drop c@ dup digit? ( n char bool, R: b u )
		if   ( n char )
			swap base @ * swap numeric? + ( accumulate number )
		else ( n char )
			drop
			r> r> ( restore string )
			exit
		then
		r> r> ( restore string )
		1 /string dup 0= ( advance string and test for end )
	until ; hidden

: >number ( n b u -- n b u : convert string )
	radix >r
	over c@ $2D = if 1 /string [-1] >r else 0 >r then ( -negative )
	over c@ $24 = if 1 /string hex then ( $hex )
	do-number
	r> if rot negate -rot then
	r> base ! ; hidden

: number? 0 -rot >number nip 0= ; ( b u -- n f : is number? )

: -trailing ( b u -- b u : remove trailing spaces )
	for
		aft =bl over r@ + c@ <
			if r> 1+ exit then
		then
	next 0 ; hidden

: lookfor ( b u c -- b u : skip until _test succeeds )
	>r
	begin
		dup
	while
		over c@ r@ - r@ =bl = _test @execute if rdrop exit then
		1 /string
	repeat rdrop ; hidden

: skipper if 0> exit else 0<> exit then ; hidden    ( n f -- f )
: scanner skipper invert ; hidden         ( n f -- f )
: skip ' skipper _test ! lookfor ; hidden ( b u c -- u c )
: scan ' scanner _test ! lookfor ; hidden ( b u c -- u c )

: parser ( b u c -- b u delta )
	>r over r> swap >r >r
	r@ skip 2dup
	r> scan swap r> - >r - r> 1+ ; hidden

: parse >r tib >in @ + #tib @ >in @ - r@ parser >in +! 
  r> bl = if -trailing then 0 max ; ( c -- b u ; <string> )
: ) ; immediate
: "(" 41 parse 2drop ; immediate
: .( 41 parse type ;
: "\" #tib @ >in ! ; immediate
: ?length dup word-length u> if 19 -throw exit then ; hidden
: word 1depth parse ?length here pack$ ;          ( c -- a ; <string> )
: token =bl word ; hidden
: char token count drop c@ ;               ( -- c; <string> )
: .s ( -- ) cr sp@ for aft r@ pick . then next .s-string print ;
: unused $4000 here - ; hidden
: .free unused u. ; hidden
: preset sp@ ndrop tib #tib cell+ ! 0 >in ! 0 _id ! ( console / io! ) ; hidden
: ] [-1] state ! ;
: [  0 state ! ; immediate

: .error ( n -- )
	abs dup 60 < loaded @ and
	if
		dup l/b / + 32 + _message @execute
	else
		negate . cr
	then ; hidden

: ?error ( n -- : perform actions on error )
	?dup if
		[char] ? emit ( print error message )
		.error
		preset        ( reset machine )
		[             ( back into interpret mode )
		exit
	then ; hidden

: ?dictionary dup $3f00 u> if 8 -throw exit then ; hidden
: , here dup cell+ ?dictionary cp ! ! ; ( u -- )
: doLit 0x8000 or , ; hidden
: ?compile state @ 0= if 14 -throw exit then ; hidden ( fail if not compiling )
: literal ( n -- : write a literal into the dictionary )
	?compile
	dup 0x8000 and ( n > $7fff ? )
	if
		invert doLit =invert , exit ( store inversion of n the invert it )
	else
		doLit exit ( turn into literal, write into dictionary )
	then ; immediate

: make-callable 2/ $4000 or ; hidden ( cfa -- instruction )
: compile, make-callable , ;         ( cfa -- : compile a code field address )
: $compile dup inline? if cfa @ , else cfa compile, then ; hidden ( pwd -- )

: interpret ( ??? a -- ??? : The command/compiler loop )
	find ?dup if
		state @
		if
			0> if \ immediate
				cfa execute exit
			else
				$compile exit
			then
		else
			drop cfa execute exit
		then
	else \ not a word
		dup count number? if
			nip
			state @ if literal exit then
		else
			drop space print 13 -throw exit
		then
	then ;

: "immediate" last address $4000 toggle ;
: .ok state @ 0= if space OK print space then cr ;
: eval begin token dup count nip while interpret repeat drop _prompt @execute ; hidden
: quit quitLoop: preset [ begin query ' eval catch ?error again ;

: evaluate ( a u -- )
	_prompt @ >r  0 _prompt !
	_id     @ >r [-1] _id !
	>in     @ >r  0 >in !
	source >r >r
	#tib 2!
	' eval catch
	r> r> #tib 2!
	r> >in !
	r> _id !
	r> _prompt !
	throw ;

: ccitt ( crc c -- crc : calculate polynomial $1021 AKA "x16 + x12 + x5 + 1" )
	over 256/ xor        ( crc x )
	dup  4  rshift xor   ( crc x )
	dup  5  lshift xor   ( crc x )
	dup  12 lshift xor   ( crc x )
	swap 8  lshift xor ; ( crc )

: crc ( b u -- u : calculate ccitt-ffff CRC )
	$ffff >r
	begin
		dup
	while
		over c@ r> swap ccitt >r 1 /string
	repeat 2drop r> ;

: random seed @ dup 15 lshift ccitt dup iTimerDin @ + seed ! ; ( -- u )

: 5u.r 5 u.r ; hidden
: dm+ 2/ for aft dup @ space 5u.r cell+ then next ; ( a u -- a )
: colon 58 emit ; hidden ( -- )

: dump ( a u -- )
	dump-width /
	for
		aft
			cr dump-width 2dup
			over 5u.r colon space
			dm+ -rot
			2 spaces $type
		then
	next drop ;

: CSI $1b emit [char] [ emit ; hidden
: 10u. base @ >r decimal <# #s #> type r> base ! ; hidden ( u -- )
: ansi swap CSI 10u. emit ; ( n c -- )
: at-xy CSI 10u. $3b emit 10u. [char] H emit ; ( x y -- )
: page 2 [char] J ansi 1 1 at-xy ; ( -- )
: sgr [char] m ansi ; ( -- )

( ==================== Advanced I/O Control ========================== )

: segments! o7SegLED ! ;   ( u -- : display a number on the LED 7 segment display )
: led!      oLeds ! ;      ( u -- : write to LED lights )
: switches  iSwitches  @ ; ( -- u : get the state of the switches)
: timer!    oTimerCtrl ! ; ( u -- )
: timer     iTimerDin  @ ; ( -- u )
: input rx? if [-1] else ps2? then ; hidden ( -- c -1 | 0 : UART and PS/2 Input )
: output dup tx! vga! ; hidden ( c -- : write to UART and VGA display )
: printable? 32 127 within ; hidden ( c -- f )
: pace 11 emit ; hidden
: xio  ' accept _expect ! _tap ! _echo ! _prompt ! ; hidden
: file ' pace ' "drop" ' ktap xio ;
: star $2A emit ; hidden
: [conceal] dup 33 127 within if drop star else output then ; hidden
: conceal ' .ok ' [conceal] ' ktap xio ;
: hand ' .ok  '  emit  ' ktap xio ; hidden
: console ' rx? _key? ! ' tx! _emit ! hand ;
: interactive ' input _key? ! ' output _emit ! hand ;
: io! $8FFF oTimerCtrl ! interactive 0 ien oIrcMask ! ; ( -- : initialize I/O )
: ver $666 ;
: hi io! ( save ) hex cr hi-string print ver <# # # 46 hold # #> type cr here . .free cr [ ;

( ==================== Advanced I/O Control ========================== )

( ==================== Control Structures ============================ )

( The following section implements the control structures and high level
words used for interpreting Forth. As much error checking is done
as possible so the Forth environment is easy to use. )

( @note The word ';' currently throws an exception when it is ran in compile
mode, this is so a Forth block can have it's first word as ';' to stop
thru from executing it - thru should then ignore it, but it does not at the
moment. Another useful word would be one that lists the currently loaded
block then stops evaluation of the loaded block, this would be useful for
displaying block files as they are read in )


: !csp sp@ csp ! ; hidden
: ?csp sp@ csp @ xor if 22 -throw exit then ; hidden
: +csp csp 1+! ; hidden
: -csp csp 1-! ; hidden
: ?unique dup last search if drop redefined print cr exit else drop exit then ; hidden ( a -- a )
: ?nul count 0= if 16 -throw exit then 1- ; hidden ( b -- : check for zero length strings )
: find-cfa token find if cfa exit else 13 -throw exit then ; hidden
: "'" find-cfa state @ if literal exit then ; immediate
: [compile] ?compile find-cfa compile, ; immediate ( -- ; <string> )
: compile  r> dup @ , cell+ >r ; ( -- : Compile next compiled word NB. Works for words, instructions, and numbers below $8000 )
: "[char]" ?compile char literal ; immediate ( --, <string> : )
: ?quit state @ 0= if 56 -throw exit then ; hidden
: ";" ?quit ( ?compile ) +csp ?csp context @ ! =exit , ( save )  [ ; immediate
: ":" align ( save ) !csp here dup last-def ! last address ,  token ?nul ?unique count + aligned cp ! ] ;
: jumpz, 2/ $2000 or , ; hidden
: jump, 2/ ( $0000 or ) , ; hidden
: "begin" ?compile here -csp ; immediate
: "until" ?compile jumpz, +csp ; immediate
: "again" ?compile jump, +csp ; immediate
: "if" ?compile here 0 jumpz, -csp ; immediate
: doThen  here 2/ over @ or swap ! ; hidden
: "then" ?compile doThen +csp ; immediate
: "else" ?compile here 0 jump, swap doThen ; immediate
: "while" ?compile call "if" ; immediate
: "repeat" ?compile swap call "again" call "then" ; immediate
: recurse ?compile last-def @ address cfa compile, ; immediate
\ : tail ?compile last-def @ address cfa jump, ; immediate
: create call ":" compile doVar context @ ! [ ;
: doDoes r> 2/ here 2/ last-def @ address cfa dup cell+ doLit ! , ; hidden
: does> ?compile compile doDoes nop ; immediate
: "variable" create 0 , ;
: ":noname" here ] !csp ;
: "for" ?compile =>r , here -csp ; immediate
: "next" ?compile compile doNext , +csp ; immediate
: "aft" ?compile drop here 0 jump, call "begin" swap ; immediate
: doer create =exit last-def @ cfa ! =exit ,  ;
: make
	find-cfa find-cfa make-callable
	state @
	if
		literal literal compile ! exit
	else
		swap ! exit
	then ; immediate

: "constant" create ' doConst make-callable here cell- ! , ;

\ : [leave] rdrop rdrop rdrop ; hidden
\ : leave ?compile compile [leave] ; immediate
\ : [do] r> dup >r swap rot >r >r cell+ >r ; hidden
\ : do ?compile compile [do] 0 , here ; immediate
\ : [loop]
\     r> r> 1+ r> 2dup <> if >r >r @ >r exit then
\     >r 1- >r cell+ >r ; hidden
\ : [unloop] r> rdrop rdrop rdrop >r ; hidden
\ : loop compile [loop] dup , compile [unloop] cell- here 2/ swap ! ; immediate
\ : [i] r> r> tuck >r >r ; hidden
\ : i ?compile compile [i] ; immediate
\ : [?do]
\    2dup <> if r> dup >r swap rot >r >r cell+ >r exit then 2drop exit ; hidden
\ : ?do  ?compile compile [?do] 0 , here ; immediate


\ : back here cell- @ ; hidden ( a -- : get previous cell )
\ : call? back $e000 and $4000 = ; hidden ( -- f : is call )
\ : merge? back dup $e000 and $6000 = swap $1c and 0= and ; hidden ( -- f : safe to merge exit )
\ : redo here cell- ! ; hidden
\ : merge back $1c or redo ; hidden
\ : tail-call back $1fff and redo ; hidden ( -- : turn previously compiled call into tail call )
\ : compile-exit call? if tail-call else merge? if merge else =exit , then then ; hidden
\ : compile-exit call? if tail-call else merge? if merge then then =exit , ; hidden
\ : "exit" compile-exit ; immediate
\ : "exit" =exit , ; immediate

( Error recovery can be quite difficult when sending Forth large programs
over a serial port. One of the problems is if an error occurs in between a
colon definition the Forth interpreter would signal an error and go back into
command mode, subsequently words which are meant to be compiled are instead
executed which can cause the system to become unstable. There are potential
ways of getting around this:

1. The sender stops upon encountering an error
2. The receiver discards all input until the end of the file [if it can work
out when that is].
3. A third interpreter state in which words are discarded until a closing
';' is encountered.

To keep things simple non of these methods are used, but they highlight ways
in which the problem could be solved. )

( ==================== Control Structures ============================ )

( ==================== Strings ======================================= )

: do$ r> r@ r> count + aligned >r swap >r ; hidden ( -- a )
: $"| do$ nop ; hidden                             ( -- a : do string NB. nop needed to fool optimizer )
: ."| do$ print ; hidden                           ( -- : print string )
: $,' 34 word count + aligned cp ! ; hidden        ( -- )
: $"  ?compile compile $"| $,' ; immediate         ( -- ; <string> )
: ."  ?compile compile ."| $,' ; immediate         ( -- ; <string> )
\ : abort 0 rp! quit ;                               ( --, R: ??? --- ??? : Abort! )
\ : abort" ?compile ." compile abort ; immediate

( ==================== Strings ======================================= )

( ==================== Block Word Set ================================ )
\ @todo 'blk' being set to zero should indicate an invalid block number, not -1
\ The usuage of 'blk' is incorrect, it should be set to the block number
\ most recently LOAD'ed, not the one most recently BLOCK'ed
\ 
\ @todo Make a memory mapped version of 'block', which includes the main
\ memory from blocks 1-16, SRAM, then Flash, with zero as the invalid block
\ number.

: updated? block-dirty @ ; hidden      ( -- f )
: update [-1] block-dirty ! ;          ( -- )
: +block blk @ + ;                     ( n -- k )
: clean-buffers 0 block-dirty ! ; hidden
: empty-buffers clean-buffers block-invalid blk ! ;  ( -- )
: save-buffers                         ( -- )
	blk @ block-invalid = updated? 0= or if exit then
	block-buffer b/buf blk @ _bsave @execute throw
	clean-buffers ;
: flush save-buffers empty-buffers ;

: block ( k -- a )
	1depth
	_binvalid @execute                         ( check validity of block number )
	dup blk @ = if drop block-buffer exit then ( block already loaded )
	flush
	dup >r block-buffer b/buf r> _bload @execute throw 
	blk !
	block-buffer ;

: line swap block swap c/l * + c/l ; hidden ( k u -- a u )
: loadline line evaluate ; hidden ( k u -- )
: load 0 l/b 1- for 2dup >r >r loadline r> r> 1+ next 2drop ;
: pipe 124 emit ; hidden
: .line line -trailing $type ; hidden
: .border border @ if 3 spaces c/l 45 nchars cr exit then ; hidden
: #line border @ if dup 2 u.r exit then ; hidden ( u -- u : print line number )
: ?pipe border @ if pipe exit then ; hidden
: ?page border @ if page exit then ; hidden
( @todo 'thru' should catch -56, or QUIT, and continue with next block )
\ : ?load ' load catch dup -56 <> if throw then drop ;
: thru over - for dup load 1+ next drop ; ( k1 k2 -- )
: blank =bl fill ;
: message l/b extract .line cr ; ( u -- )
: list
	?page
	cr
	.border
	0 begin
		dup l/b <
	while
		2dup #line ?pipe line $type ?pipe cr 1+
	repeat .border 2drop ;

: index ( k1 k2 -- : show titles for block k1 to k2 )
	over - cr
	for
		dup 5u.r space pipe space dup  0 .line cr 1+
	next drop ;

\ 'block-copy' is a hack, but an elegant one, it relies on modifying 
\ the 'blk' variable to trick the block system into thinking that a different
\ block has been loaded. This works as their is only one block available, it
\ could work in other systems by modifying the block buffers data structures
\ in systems with more than one block buffer.
\ : block-copy swap block drop blk ! update save-buffers ; ( k1 k2 -- : copy k1 to k2 )


( all words before this are now in the forth vocabulary, it is also set
later on )
.set forth-wordlist $pwd

( ==================== Block Word Set ================================ )

( ==================== See =========================================== )

( @warning This disassembler is experimental, and liable not
to work / break everything it touches )

: bcounter! bcount @ 0= if 2/ over swap -  bcount ! else drop then ; hidden ( u a -- u )
: -bcount   bcount @ if bcount 1-! then ; hidden ( -- )
: abits $1fff and ; hidden

: validate ( cfa pwd -- nfa | 0 )
	tuck cfa <> if drop 0 else nfa then ; hidden

( @todo Do this for every vocabulary loaded )
: name ( cfa -- nfa )
	abits 2*
	>r
	last address
	begin
		dup
	while
		address dup r@ swap dup @ address swap within ( simplify? )
		if @ address r> swap validate exit then
		address @
	repeat rdrop ; hidden

: .name name ?dup 0= if see.unknown then print ; hidden
: mask-off 2dup and = ; hidden ( u u -- u f )

i.end2t: 2*
i.end:   5u.r rdrop exit
: i.print print abits ; hidden

( @note A recursive version of 'see' that decompiled no-name words would complicate
things, the 'decompiler' word could be called manually on an address if desired )
: instruction ( decode instruction )
	over >r
	0x8000 mask-off if see.lit     print $7fff and      branch i.end then
	$6000  mask-off if see.alu     i.print              branch i.end then
	$4000  mask-off if see.call    i.print dup 2*       5u.r rdrop space .name exit then
	$2000  mask-off if see.0branch i.print r@ bcounter! branch i.end2t then
	                   see.branch  i.print r@ bcounter! branch i.end2t ; hidden

: continue? ( u a -- f : determine whether to continue decompilation  )
	bcount @ if 2drop [-1] exit then
	over $e000 and 0= if u> exit else drop then
	dup ' doVar make-callable = if drop 0 exit then ( print next address ? )
	=exit and =exit <> ; hidden

: decompile ( a -- a : decompile a single instruction )
	dup 5u.r colon dup @ 5u.r space
	dup @ instruction
	dup @ ' doNext make-callable = if cell+ dup ? then
	cr
	cell+ ; hidden

: decompiler ( a -- : decompile starting at address )
	0 bcount !
	dup 2/ >r
	begin dup @ r@ continue? while decompile -bcount ( nuf? ) repeat decompile rdrop
	drop ; hidden

: see ( --, <string> : decompile a word )
	token find 0= if 13 -throw exit then
	cr colon space dup .id space
	dup inline?    if see.inline    print then
	dup immediate? if see.immediate print then
	cr
	cfa decompiler space 59 emit cr ;

\ : see
\ 	token find 0= if 13 -throw exit then
\ 	begin nuf? while
\ 		dup @ dup $4000 and $4000
\ 		= if space .name else . then cell+
\ 	repeat drop ;

.set forth-wordlist $pwd
( ==================== See =========================================== )

( ==================== Miscellaneous ================================= )

\ Testing for the interrupt mechanism, interrupts do not
\ work correctly at the moment

( @bug Interrupts work in simulation but not in hardware )
variable #irq 0

: doIrq 
	0 ien drop
	switches led!
	#irq 1+!
	#irq @ segments!
        1 ien drop ; hidden

irqTask: doIrq nop exit

 \ doIrq nop exit 

.set 2 irqTask
.set 4 irqTask
.set 6 irqTask
.set 8 irqTask
.set 10 irqTask
.set 12 irqTask
.set 14 irqTask

: irq $0040 oIrcMask ! $efff oTimerCtrl !  1 ien drop ;

\ : irqTest2
\	$0080 oIrcMask !
\	1 ien drop ; )

( ==================== Miscellaneous ================================= )

( ==================== Vocabulary Words ============================== )

: find-empty-cell begin dup @ while cell+ repeat ; hidden ( a -- a )

: get-order ( -- widn ... wid1 n : get the current search order )
	context
	find-empty-cell
	dup cell- swap
	context - 2/ dup >r 1- dup 0< if 50 -throw exit then
	for aft dup @ swap cell- then next @ r> ;

: set-order ( widn ... wid1 n -- : set the current search order )
	dup [-1]  = if drop forth-wordlist 1 set-order exit then
	dup #vocs > if 49 -throw exit then
	context swap for aft tuck ! cell+ then next 0 swap ! ;

\ : root  -1 set-order ; \ should contain set-order, forth-wordlist, forth, and words
: forth -1 set-order ;
: flash get-order flash-voc swap 1+ set-order ;

: .words space begin dup while dup .id space @ address repeat drop cr ; hidden
: words get-order begin ?dup while swap dup cr u. colon @ .words 1- repeat ;
\ : vocs get-order begin ?dup while swap dup . space cell- 2/ .name 1- repeat cr ;

.set forth-wordlist $pwd

( ==================== Vocabulary Words ============================== )

( ==================== Memory Interface ============================== )

( @note The manual for the Nexys 3 board specifies that there is a PCM
memory device called the NP8P128A13T1760E, this is a device behaves like
normal flash with the addition that individual cells can be written to
without first erasing the block, this is accomplished with an extension
to the Common Flash Interface that most flash devices support. However,
there are boards the PC28F128P33BF60 on in lieu of this, which is a
normal flash device without the "bit alterable write" extension. Normal
flash memory works by erasing a block of data, setting all bits set,
writing the memory works by masking in a value, bits can be cleared in
a memory cell but not set, the can only be set by erasing a block.

The Nexys 3 has three memory devices, two of which are accessed over
a parallel interface. They share the same data and address bus, and
can be selected with a chip select. The signals to be controlled
are:

	+-----+-------------------------+
	| Bit | Description             |
	|-----|-------------------------|
	| 0-9 | Upper Memory Bits       |
	| 10  | Flash chip select       |
	| 11  | SRAM chip select        |
	| 12  | Memory Wait [not used]  |
	| 13  | Flash Reset             |
	| 14  | Output Enable           |
	| 15  | Write Enable            |
	+-----+-------------------------+

The usage of the output enable and write enable are mutually exclusive,
as are both of the chip selects.

)

.set context forth-wordlist
.set forth-wordlist $pwd
.pwd 0

constant memory-upper-mask  $1ff hidden
variable memory-upper       0    ( upper bits of external memory address )
location memory-select      0    ( SRAM/Flash select SRAM = 0, Flash = 1 )

: mcontrol! ( u -- : write to memory control register )
	$f3ff and
	memory-select @ if $400 else $800 then or  ( select correct memory device )
	memory-upper-mask invert    and            ( mask off control bits )
	memory-upper @ memory-upper-mask and or         ( or in higher address bits )
	oMemControl ! ; hidden            ( and finally write in control )

: m! ( n a -- : write to non-volatile memory )
	oMemAddrLow !
	oMemDout !
	5 40ns
	0x8000 mcontrol!
	5 40ns
	$0000 mcontrol! ;

: m@ ( a -- n : read from non-volatile memory )
	oMemAddrLow !
	$4000 mcontrol! ( read enable mode )
	5 40ns
	iMemDin @        ( get input )
	$0000 mcontrol! ;

\ : memory-dump ( a u -- : dump non-volatile memory )
\  	cr
\  	begin
\  		dup
\  	while
\  		over 5u.r 40 emit over m@ 4 u.r 41 emit over 1+ $7 and 0= if cr then
\  		1 /string
\  	repeat 2drop cr ;

: sram 0 memory-select ! ;
: nvram [-1] memory-select ! ; hidden
: block-mode 0 memory-upper substitute ; hidden ( -- hi )
: flash-reset ( -- : reset non-volatile memory )
	$2000 mcontrol!
	5 40ns
	$0000 mcontrol! ; hidden
: flash! dup >r m! r> m! ; hidden ( u u a )
: flash-status nvram $70 0 m! 0 m@ ( dup $2a and if -34 -throw exit then ) ; ( -- status )
: flash-read   $ff 0 m! ;      ( -- )
: flash-setup  memory-select @ 0= if flush then nvram flash-reset block-mode drop 20 ms ;
: flash-wait begin flash-status $80 and until ; hidden
: flash-clear $50 0 m! ; ( -- clear status )
: flash-write $40 swap flash! flash-wait ; ( u a -- )
: flash-unlock block-mode >r $d0 swap $60 swap flash! r> memory-upper ! ; ( ba -- )
\ : flash-lock block-mode >r $01 swap $60 swap flash! r> memory-upper ! ; ( ba -- )
\ : flash-lock-down block-mode >r $2f swap $60 swap flash! r> memory-upper ! ; ( ba -- )
: flash-erase block-mode >r flash-clear $d0 swap $20 swap flash! flash-wait r> memory-upper ! ; ( ba -- )
: flash-query $98 0 m! ; ( -- : query mode )
\ : flash-read-id   $90 0 m! ; ( -- read id mode : does the same as flash-query on the PC28F128P33BF60 )

: flash->sram ( a a : transfer flash memory cell to SRAM )
	[-1] memory-select ! flash-clear flash-read
	m@ 0 memory-select ! swap m! ; hidden

: transfer ( a a u -- : transfer memory block from Flash to SRAM )
	?dup 0= if 2drop exit then
	1-
	for
		2dup
		flash->sram
		cell+ swap cell+ swap
	next 2drop ;
.set flash-voc $pwd

: minvalid ( k -- k : is 'k' a valid block number, throw on error )
	dup block-invalid = if 35 -throw exit then ; hidden

: c>m swap @ swap m! ; hidden      ( a a --  )
: m>c m@ swap ! ; hidden ( a a -- )

: mblock ( a u k -- f )
	minvalid
	b/buf um* memory-upper ! >r
	begin
		dup
	while
		over r@ _blockop @execute r> cell+ >r
		cell /string
	repeat
	rdrop 2drop 0 ; hidden

: memory-save ' c>m _blockop ! mblock ; hidden
: memory-load ' m>c _blockop ! mblock ; hidden

( ==================== Memory Interface ============================== )

( ==================== Startup Code ================================== )

: .failed failed print ; hidden
: boot ( -- )
	0 0 $8000 transfer
	0 block c@ printable? if
		0 load
	else
		1 -throw exit
	then ; hidden

start:
.set entry start
	_boot @execute  ( _boot contains zero by default, does nothing )
	hex io! [
	\ irq
	hi
	cpu-id segments!
	loading-string print
	' boot catch if .failed else .ok then
	\ loaded @ if 1 list then
	\ login 0 load 1 list
	branch quitLoop ( jump to main interpreter loop if _boot returned )

( ==================== Startup Code ================================== )

.set cp  $pc

.set _key?     input       ( execution vector of ?key,   default to input. )
.set _emit     output      ( execution vector of emit,   default to output )
.set _expect   accept      ( execution vector of expect, default to 'accept'. )
.set _tap      ktap        ( execution vector of tap,    default the ktap. )
.set _echo     output      ( execution vector of echo,   default to output. )
.set _prompt   .ok         ( execution vector of prompt, default to '.ok'. )
.set _boot     0           ( @execute does nothing if zero )
.set _bload    memory-load ( execution vector of _bload, used in block )
.set _bsave    memory-save ( execution vector of _bsave, used in block )
.set _binvalid minvalid    ( execution vector of _invalid, used in block )
.set _message  message     ( execution vector of _message, used in ?error )
