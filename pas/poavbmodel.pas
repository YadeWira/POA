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
{ POA_FAST: the release build of the model, without range and overflow
  checks (every table index here is masked to the table's size). The test
  builds keep them. }
{$ifdef POA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal poavbmodel: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal poavbmodel: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, poacm, poavorbis;

const
  VM_INPUTS = 10;
  VM_TAB_BITS = 22;             { the most; smaller inputs get smaller tables (TableBits) }
  VM_HIST_BITS = 18;

type
  { Floor 1 of one channel in the packet being coded, rebuilt as the
    decoder does (step 2 of the specification) from the values coded so
    far, so that later values and the residue can be predicted from it. }
  TFloorTrack = record
    Used: Boolean;
    Fl: ^TFloor1;
    Done: Integer;                    { posts with a final value: 0..Done }
    Raw, Fin: array[0..64] of Integer;
    Curve: array of Byte;             { floor level per spectral bin (0..255) }
  end;

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
    SlotBase: array[0..VM_INPUTS - 1] of SizeInt;  { slot of node 0 for each context }
    Slots: array[0..VM_INPUTS - 1] of SizeInt;
    TailT: TCtxTable;
    Mode: Integer;
    Fl: array[0..255] of TFloorTrack;
    CurvesReady: Boolean;
    procedure FloorStart(ch: Integer);
    procedure FloorAdvance(ch, upto: Integer);
    function FloorPredict(ch, i: Integer): Integer;
    procedure BuildCurves;
    function ResidueLevel(const ev: TVbEvent): Integer;
    function CodeBit(var ac: TArith; bit, node, sel: Integer): Integer;
    function PlaceKey(const ev: TVbEvent; withCh: Boolean): LongWord;
  public
    TabMask: SizeInt;
    TabPtr: array[0..VM_INPUTS - 1] of PLongWord;
    { tabBits: log2 of each context table's slots (TableBits of the input size) }
    constructor Create(tabBits: Integer = VM_TAB_BITS);
    procedure SetSetup(const s: TVorbisSetup);
    procedure StartPacket;
    { Codes ev.Val (encoding) or fills it (decoding). }
    procedure CodeEvent(var ac: TArith; var ev: TVbEvent);
    { The tail of a packet: nbits bits, given (encoding) or read. }
    procedure CodeTail(var ac: TArith; var bits: TBytes; nbits: SizeInt);
  end;

{ Table size for an input of n bytes: about 2 slots per input byte, at
  least 2^16, at most 2^VM_TAB_BITS. Part of the format: the decoder
  derives it from the size in the header. }
function TableBits(n: QWord): Integer;

var
  { Statistics for tuning: bits spent per tag (only when VbStats is set). }
  VbStats: Boolean = False;
  VbCost: array[TVbTag] of Double;
  VbCount: array[TVbTag] of Int64;
  CurTag: TVbTag;

type
  { Symbols from the model, for the walker when decompressing. }
  TVbModelSource = class(TVbSource)
    Model: TVbModel;
    Ac: ^TArith;
    function Raw(const ev: TVbEvent): LongWord; override;
    function Code(const ev: TVbEvent): Integer; override;
  end;

implementation

function TableBits(n: QWord): Integer;
begin
  Result := 16;
  while (Result < VM_TAB_BITS) and ((QWord(1) shl (Result - 1)) < n) do Inc(Result);
end;

constructor TVbModel.Create(tabBits: Integer);
var
  i: Integer;
begin
  inherited Create;
  if tabBits > VM_TAB_BITS then tabBits := VM_TAB_BITS;
  if tabBits < 12 then tabBits := 12;
  TabMask := (SizeInt(1) shl tabBits) - 1;
  for i := 0 to VM_INPUTS - 1 do
  begin
    T[i].Init(tabBits);
    TabPtr[i] := @T[i].S[0];
  end;
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
var
  c: Integer;
begin
  Inc(Stamp);
  BlockFlag := 0;
  Mode := -1;
  CurvesReady := False;
  for c := 0 to 255 do Fl[c].Used := False;
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

{ ---- floor tracking ---- }

function RenderPoint(x0, y0, x1, y1, x: Integer): Integer;
var
  dy, adx, ady, err, off: Integer;
begin
  dy := y1 - y0;
  adx := x1 - x0;
  if adx <= 0 then Exit(y0);
  ady := Abs(dy);
  err := ady * (x - x0);
  off := err div adx;
  if dy < 0 then Result := y0 - off else Result := y0 + off;
end;

procedure TVbModel.FloorStart(ch: Integer);
var
  m: ^TMapping;
  f: ^TFloor;
begin
  Fl[ch].Used := False;
  Fl[ch].Fl := nil;
  if (Mode < 0) or (ch >= Setup^.Channels) then Exit;
  m := @Setup^.Mappings[Setup^.Modes[Mode].Mapping];
  f := @Setup^.Floors[m^.SubFloor[m^.Mux[ch]]];
  if f^.FType <> 1 then Exit;
  Fl[ch].Used := True;
  Fl[ch].Fl := @f^.F1;
  Fl[ch].Done := -1;
  FillChar(Fl[ch].Raw, SizeOf(Fl[ch].Raw), 0);
end;

{ The value predicted for post i from its two neighbours' final values. }
function TVbModel.FloorPredict(ch, i: Integer): Integer;
var
  f: ^TFloor1;
begin
  f := Fl[ch].Fl;
  Result := RenderPoint(f^.X[f^.LowN[i]], Fl[ch].Fin[f^.LowN[i]],
                        f^.X[f^.HighN[i]], Fl[ch].Fin[f^.HighN[i]], f^.X[i]);
end;

{ Final values for posts Done+1 .. upto-1 (posts never coded count as 0). }
procedure TVbModel.FloorAdvance(ch, upto: Integer);
var
  f: ^TFloor1;
  i, pred, val, hiroom, loroom, room, fin: Integer;
begin
  f := Fl[ch].Fl;
  if upto > Length(f^.X) then upto := Length(f^.X);
  for i := Fl[ch].Done + 1 to upto - 1 do
  begin
    if i < 2 then
      fin := Fl[ch].Raw[i]
    else
    begin
      pred := FloorPredict(ch, i);
      val := Fl[ch].Raw[i];
      hiroom := f^.Range - pred;
      loroom := pred;
      if hiroom < loroom then room := hiroom * 2 else room := loroom * 2;
      if val = 0 then
        fin := pred
      else if val >= room then
      begin
        if hiroom > loroom then fin := val - loroom + pred
        else fin := pred - val + hiroom - 1;
      end
      else if Odd(val) then
        fin := pred - (val + 1) div 2
      else
        fin := pred + val div 2;
    end;
    if fin < 0 then fin := 0;
    if fin > 255 then fin := 255;
    Fl[ch].Fin[i] := fin;
    Fl[ch].Done := i;
  end;
end;

procedure TVbModel.BuildCurves;
var
  ch, n, k, b, x0, x1, y0, y1, mult, v: Integer;
  f: ^TFloor1;
begin
  CurvesReady := True;
  if BlockFlag <> 0 then n := Setup^.Block1 div 2 else n := Setup^.Block0 div 2;
  for ch := 0 to Setup^.Channels - 1 do
  begin
    if not Fl[ch].Used then Continue;
    f := Fl[ch].Fl;
    FloorAdvance(ch, Length(f^.X));
    SetLength(Fl[ch].Curve, n);
    mult := f^.Multiplier;
    k := 0;
    x0 := f^.X[f^.Sorted[0]];
    y0 := Fl[ch].Fin[f^.Sorted[0]] * mult;
    for b := 0 to n - 1 do
    begin
      while (k < High(f^.Sorted)) and (f^.X[f^.Sorted[k + 1]] <= b) do
      begin
        Inc(k);
        x0 := f^.X[f^.Sorted[k]];
        y0 := Fl[ch].Fin[f^.Sorted[k]] * mult;
      end;
      if k < High(f^.Sorted) then
      begin
        x1 := f^.X[f^.Sorted[k + 1]];
        y1 := Fl[ch].Fin[f^.Sorted[k + 1]] * mult;
        v := RenderPoint(x0, y0, x1, y1, b);
      end
      else
        v := y0;
      if v < 0 then v := 0;
      if v > 255 then v := 255;
      Fl[ch].Curve[b] := v;
    end;
  end;
end;

{ The floor level where a residue partition lies (0..255). }
function TVbModel.ResidueLevel(const ev: TVbEvent): Integer;
var
  m: ^TMapping;
  r: ^TResidue;
  sm, c, nch, idx, bin, v: Integer;
begin
  Result := 0;
  if Mode < 0 then Exit;
  if not CurvesReady then BuildCurves;
  m := @Setup^.Mappings[Setup^.Modes[Mode].Mapping];
  if ev.Ch >= Setup^.Channels then Exit;
  sm := m^.Mux[ev.Ch];
  r := @Setup^.Residues[m^.SubResidue[sm]];
  idx := r^.RBegin + Integer(ev.Pos) * r^.PartSize + r^.PartSize div 2;
  if r^.RType = 2 then
  begin
    nch := 0;
    for c := 0 to Setup^.Channels - 1 do
      if m^.Mux[c] = sm then Inc(nch);
    if nch = 0 then Exit;
    bin := idx div nch;
    for c := 0 to Setup^.Channels - 1 do
      if (m^.Mux[c] = sm) and Fl[c].Used and (bin < Length(Fl[c].Curve)) then
      begin
        v := Fl[c].Curve[bin];
        if v > Result then Result := v;
      end;
  end
  else if Fl[ev.Ch].Used and (idx < Length(Fl[ev.Ch].Curve)) then
    Result := Fl[ev.Ch].Curve[idx];
end;

{ One bit: every table's prediction, mixed, refined by the APM, coded,
  then everything updated. Written out in full (no calls into poacm in
  the loops) because this is where the time goes. }
function TVbModel.CodeBit(var ac: TArith; bit, node, sel: Integer): Integer;
var
  i, pr, pa, p, n, err, q: Integer;
  st: array[0..VM_INPUTS] of Integer;
  sp: array[0..VM_INPUTS - 1] of PLongWord;
  dot: Int64;
  w: PInteger;
  v: LongWord;
begin
  dot := 0;
  w := @Mx.W[sel * Mx.NIn];
  for i := 0 to VM_INPUTS - 1 do
  begin
    sp[i] := @TabPtr[i][(SlotBase[i] + node) and TabMask];
    q := StretchTab[(sp[i]^ and $FFFF) shr 4];
    st[i] := q;
    dot := dot + Int64(q) * w[i];
  end;
  st[VM_INPUTS] := 256;
  dot := dot + Int64(256) * w[VM_INPUTS];
  dot := SarInt64(dot, 16);
  if dot > 2047 then dot := 2047;
  if dot < -2047 then dot := -2047;
  pr := SquashTab[Integer(dot)];
  pa := Apm1.Refine(pr, (sel * 4 + (node and 3)) and (16 * 64 - 1));
  q := (pr + 3 * pa) div 4;
  Result := ac.Code(bit, q * 16);
  if VbStats then
    if Result <> 0 then VbCost[CurTag] := VbCost[CurTag] - Ln(q / 4096) / Ln(2)
    else VbCost[CurTag] := VbCost[CurTag] - Ln(1 - q / 4096) / Ln(2);
  { tables }
  for i := 0 to VM_INPUTS - 1 do
  begin
    v := sp[i]^;
    p := v and $FFFF;
    n := v shr 16;
    if Result <> 0 then
      p := p + (((65535 - p) * RateTab[n]) shr 16)
    else
      p := p - ((p * RateTab[n]) shr 16);
    if p < 32 then p := 32;
    if p > 65503 then p := 65503;
    if n < 127 then Inc(n);
    sp[i]^ := LongWord(p) or (LongWord(n) shl 16);
  end;
  { mixer }
  err := ((Result shl 12) - pr) * MIX_RATE;
  for i := 0 to VM_INPUTS do
    w[i] := w[i] + Integer(SarInt64(Int64(st[i]) * err, 14));
  Apm1.Update(Result);
end;

procedure TVbModel.CodeEvent(var ac: TArith; var ev: TVbEvent);
var
  kp, kc, prev, other, l1, l2, base: LongWord;
  hp, hc: SizeInt;
  node, nx, bit, depth, i, sel: Integer;
  fctx: LongWord;
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

  Ctx[0] := Hash3(base, LongWord(ev.Pos) or (LongWord(ev.Sub) shl 16), LongWord(ev.Pass) + 100);
  Ctx[1] := Hash3(base, l1, 200);
  Ctx[2] := Hash3(base, prev, 300 + LongWord(BlockFlag));
  Ctx[3] := Hash3(base, other, 400);
  Ctx[4] := Hash3(base, l1 or (l2 shl 16), 500);
  Ctx[5] := Hash3(base, prev or (other shl 16), 600);
  Ctx[6] := Hash3(base, prev or (l1 shl 16), 700);
  Ctx[7] := Hash3(base, LongWord(ev.Pos) or (LongWord(ev.Sub) shl 12) or (LongWord(ev.Pass) shl 20), prev + 800 * 65536);
  if VbStats then Inc(VbCount[ev.Tag]);
  { what the floor says }
  fctx := 0;
  case ev.Tag of
    vtFloorY:
      if Fl[ev.Ch].Used and (ev.Pos >= 2) and (ev.Pos < Length(Fl[ev.Ch].Fl^.X)) then
      begin
        FloorAdvance(ev.Ch, ev.Pos);
        fctx := LongWord(FloorPredict(ev.Ch, ev.Pos)) or $10000;
      end;
    vtResClass, vtResVec:
      fctx := LongWord(ResidueLevel(ev) shr 2) or (LongWord(ev.Pass) shl 8) or $20000;
  end;
  Ctx[8] := Hash3(base, fctx, 900);
  Ctx[9] := Hash3(base, fctx xor (prev shl 18), 1000 + l1);
  sel := Ord(ev.Tag) * 16;
  for i := 0 to VM_INPUTS - 1 do
    SlotBase[i] := T[i].Slot(Hash3(Ctx[i], LongWord(i), 7));

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
      node := (node shl 1) or bit;
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
  case ev.Tag of
    vtMode:
      if v < LongWord(Length(Setup^.Modes)) then
      begin
        BlockFlag := Setup^.Modes[v].BlockFlag;
        Mode := v;
      end;
    vtFloorNZ:
      if v <> 0 then FloorStart(ev.Ch) else Fl[ev.Ch].Used := False;
    vtFloorY0, vtFloorY1, vtFloorY:
      if Fl[ev.Ch].Used and (ev.Pos < Length(Fl[ev.Ch].Fl^.X)) then
      begin
        FloorAdvance(ev.Ch, ev.Pos);
        Fl[ev.Ch].Raw[ev.Pos] := v;
        FloorAdvance(ev.Ch, ev.Pos + 1);
      end;
  end;
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
    p := TailT.P(s);
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
