{ The model for Vorbis audio packets: codes each event of the walk
  (poavorbis) with the arithmetic coder, predicting it from what came
  before in the same packet, in the other channel and in the previous
  packet.

  A codebook entry is coded as the path down its codebook's tree, one bit
  per node; a node with a single child costs nothing. A raw field is coded
  bit by bit, most significant first. Every bit is predicted by several
  contexts that are mixed:

    0  the codebook (or field) and the node alone
    1  + the position in the spectrum (partition, codeword) and pass
    2  + the previous entry of this channel and pass
    3  + the entry at the same place in the previous packet of the same
         block size
    4  + the entry at the same place in the previous channel of this packet
    5  + the two previous entries
    6  + previous packet and previous channel together

  Encoding and decoding run exactly the same code (CodeEvent); the only
  difference is where the bits come from. }
unit poavbmodel;

{$I poa.inc}
{$ifopt R-}{$fatal poavbmodel: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poavbmodel: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, poacm, poavorbis;

const
  VM_INPUTS = 7;
  VM_TAB_BITS = 22;
  VM_HIST_BITS = 18;

type
  TVbModel = class
  private
    Setup: ^TVorbisSetup;
    T: array[0..VM_INPUTS - 1] of TCtxTable;
    Mx: TMixer;
    Apm1: TApm;
    PrevVal: array of LongWord;       { hash(place, block size) -> value + 1 }
    CurVal: array of LongWord;        { hash(place without channel) -> value + 1, this packet }
    CurCh: array of Byte;             { which channel wrote CurVal }
    CurStamp: array of LongWord;
    Stamp: LongWord;
    BlockFlag: Integer;
    Last1, Last2: array[0..255, 0..7] of LongWord;   { previous entries per channel and pass }
    Ctx: array[0..VM_INPUTS - 1] of LongWord;
    Slots: array[0..VM_INPUTS - 1] of SizeInt;
    TailT: TCtxTable;
    function CodeBit(var ac: TArith; bit, node, sel: Integer): Integer;
    function PlaceKey(const ev: TVbEvent; withCh: Boolean): LongWord;
  public
    constructor Create;
    procedure SetSetup(const s: TVorbisSetup);
    procedure StartPacket;
    { Codes ev.Val (encoding) or fills it (decoding). }
    procedure CodeEvent(var ac: TArith; var ev: TVbEvent);
    { The tail of a packet: nbits bits, given (encoding) or read. }
    procedure CodeTail(var ac: TArith; var bits: TBytes; nbits: SizeInt);
  end;

  { Symbols from the model, for the walker when decompressing. }
  TVbModelSource = class(TVbSource)
    Model: TVbModel;
    Ac: ^TArith;
    function Raw(const ev: TVbEvent): LongWord; override;
    function Code(const ev: TVbEvent): Integer; override;
  end;

implementation

constructor TVbModel.Create;
var
  i: Integer;
begin
  inherited Create;
  for i := 0 to VM_INPUTS - 1 do
    T[i].Init(VM_TAB_BITS);
  Mx.Init(VM_INPUTS + 1, 16 * 24);
  Apm1.Init(16 * 64);
  SetLength(PrevVal, 1 shl VM_HIST_BITS);
  SetLength(CurVal, 1 shl VM_HIST_BITS);
  SetLength(CurCh, 1 shl VM_HIST_BITS);
  SetLength(CurStamp, 1 shl VM_HIST_BITS);
  FillChar(PrevVal[0], Length(PrevVal) * SizeOf(LongWord), 0);
  FillChar(CurStamp[0], Length(CurStamp) * SizeOf(LongWord), 0);
  Stamp := 0;
  TailT.Init(12);
end;

procedure TVbModel.SetSetup(const s: TVorbisSetup);
begin
  Setup := @s;
end;

procedure TVbModel.StartPacket;
begin
  Inc(Stamp);
  BlockFlag := 0;
  FillChar(Last1, SizeOf(Last1), 0);
  FillChar(Last2, SizeOf(Last2), 0);
end;

function TVbModel.PlaceKey(const ev: TVbEvent; withCh: Boolean): LongWord;
var
  c: LongWord;
begin
  if withCh then c := ev.Ch else c := 0;
  Result := Hash3(LongWord(Ord(ev.Tag)) or (LongWord(ev.Pass) shl 8) or (c shl 16) or
                  (LongWord(BlockFlag) shl 24),
                  LongWord(ev.Pos) or (LongWord(ev.Sub) shl 16), LongWord(ev.Book) and $FFFF);
end;

function TVbModel.CodeBit(var ac: TArith; bit, node, sel: Integer): Integer;
var
  i, pr, pa: Integer;
begin
  for i := 0 to VM_INPUTS - 1 do
  begin
    Slots[i] := T[i].Slot(Hash3(Ctx[i], LongWord(node), LongWord(i)));
    Mx.Add(Stretch(T[i].Prob[Slots[i]] shr 4));
  end;
  Mx.Add(256);
  pr := Mx.Mix(sel);
  pa := Apm1.Refine(pr, (sel * 4 + (node and 3)) and (16 * 64 - 1));
  pr := (pr + 3 * pa) div 4;
  Result := ac.Code(bit, pr * 16);
  for i := 0 to VM_INPUTS - 1 do
    T[i].Update(Slots[i], Result);
  Mx.Update(Result);
  Apm1.Update(Result);
end;

procedure TVbModel.CodeEvent(var ac: TArith; var ev: TVbEvent);
var
  kp, kc, prev, other, l1, l2, base: LongWord;
  hp, hc: SizeInt;
  node, nx, bit, depth, i, sel: Integer;
  bk: ^TVorbisBook;
  v: LongWord;
begin
  kp := PlaceKey(ev, True);
  kc := PlaceKey(ev, False);
  hp := kp shr (32 - VM_HIST_BITS);
  hc := kc shr (32 - VM_HIST_BITS);
  prev := PrevVal[hp];
  if (CurStamp[hc] = Stamp) and (CurCh[hc] <> ev.Ch) then
    other := CurVal[hc]
  else
    other := 0;
  l1 := Last1[ev.Ch, ev.Pass and 7];
  l2 := Last2[ev.Ch, ev.Pass and 7];
  base := LongWord(Ord(ev.Tag)) or (LongWord(ev.Book and $FFFF) shl 8) or
          (LongWord(Ord(ev.IsCode)) shl 24);

  Ctx[0] := Hash3(base, 0, 0);
  Ctx[1] := Hash3(base, LongWord(ev.Pos) or (LongWord(ev.Sub) shl 16), LongWord(ev.Pass) + 100);
  Ctx[2] := Hash3(base, l1, 200);
  Ctx[3] := Hash3(base, prev, 300 + LongWord(BlockFlag));
  Ctx[4] := Hash3(base, other, 400);
  Ctx[5] := Hash3(base, l1 or (l2 shl 16), 500);
  Ctx[6] := Hash3(base, prev or (other shl 16), 600);
  sel := Ord(ev.Tag) * 16;

  if ev.IsCode then
  begin
    bk := @Setup^.Books[ev.Book];
    node := 0;
    depth := 0;
    v := 0;
    repeat
      { the bit of the codeword at this depth }
      if ac.Encoding then
        bit := (bk^.Codes[ev.Val] shr (bk^.Lengths[ev.Val] - 1 - depth)) and 1
      else
        bit := 0;
      if bk^.Tree[node][0] = 0 then bit := 1
      else if bk^.Tree[node][1] = 0 then bit := 0
      else
      begin
        if depth < 15 then i := depth else i := 15;
        bit := CodeBit(ac, bit, node, sel + i);
      end;
      nx := bk^.Tree[node][bit];
      Inc(depth);
      if nx < 0 then
      begin
        v := -nx - 1;
        Break;
      end;
      node := nx;
    until False;
  end
  else
  begin
    v := 0;
    node := 1;
    for depth := ev.Book - 1 downto 0 do
    begin
      if ac.Encoding then bit := (ev.Val shr depth) and 1 else bit := 0;
      if depth < 15 then i := depth else i := 15;
      bit := CodeBit(ac, bit, node, sel + i);
      v := v or (LongWord(bit) shl depth);
      node := node * 2 + bit;
      if node > $FFFFFF then node := (node and $FFFF) or $10000;
    end;
  end;
  ev.Val := v;

  { history }
  PrevVal[hp] := v + 1;
  CurVal[hc] := v + 1;
  CurCh[hc] := ev.Ch;
  CurStamp[hc] := Stamp;
  Last2[ev.Ch, ev.Pass and 7] := l1;
  Last1[ev.Ch, ev.Pass and 7] := v + 1;
  if (ev.Tag = vtMode) and (v < LongWord(Length(Setup^.Modes))) then
    BlockFlag := Setup^.Modes[v].BlockFlag;
end;

procedure TVbModel.CodeTail(var ac: TArith; var bits: TBytes; nbits: SizeInt);
var
  i, bit, s, tc: SizeInt;
  p, prevBit: Integer;
begin
  if not ac.Encoding then
  begin
    bits := nil;
    SetLength(bits, (nbits + 7) div 8);
    if Length(bits) > 0 then FillChar(bits[0], Length(bits), 0);
  end;
  prevBit := 0;
  for i := 0 to nbits - 1 do
  begin
    bit := (bits[i shr 3] shr (i and 7)) and 1;
    if nbits - i > 15 then tc := 15 else tc := nbits - i;
    tc := tc * 2 + prevBit;
    if nbits > 64 then tc := tc + 64;
    s := tc;
    p := TailT.Prob[s];
    bit := ac.Code(bit, p);
    TailT.Update(s, bit);
    if bit <> 0 then bits[i shr 3] := bits[i shr 3] or (1 shl (i and 7));
    prevBit := bit;
  end;
end;

function TVbModelSource.Raw(const ev: TVbEvent): LongWord;
var
  e: TVbEvent;
begin
  e := ev;
  Model.CodeEvent(Ac^, e);
  Result := e.Val;
end;

function TVbModelSource.Code(const ev: TVbEvent): Integer;
var
  e: TVbEvent;
begin
  e := ev;
  Model.CodeEvent(Ac^, e);
  Result := e.Val;
end;

end.
