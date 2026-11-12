{ The entropy coder and the pieces the models are built from.

  - TArith: a binary arithmetic coder, 32-bit range, probabilities of 16
    bits. The same object encodes or decodes; Code(bit, p) returns the bit
    (the one given when encoding, the one read when decoding).
  - TCtxTable: adaptive bit probabilities addressed by a hashed context.
    Each slot learns fast at first and slower as it sees more bits.
  - TMixer: logistic mixing of several predictions, with weight sets
    selected by a small context.

  Everything is integer arithmetic, so encoder and decoder compute the
  same numbers on every platform. }
unit poacm;

{$I poa.inc}
{ POA_FAST: the release build of the model, without range and overflow
  checks (every table index here is masked to the table's size). The test
  builds keep them. }
{$ifdef POA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal poacm: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal poacm: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils;

const
  CM_MAX_INPUTS = 16;
  MIX_RATE = 10;               { mixer learning rate, in 1/16384 }

type
  TArith = record
    Encoding: Boolean;
    X1, X2, X: LongWord;
    Buf: TBytes;                { encoding: output; decoding: input }
    BufPos: SizeInt;
    procedure InitEncode;
    procedure InitDecode(const a: TBytes; first: SizeInt);
    function Code(bit: Integer; p16: Integer): Integer;   { p16 = P(bit = 1) * 65536 }
    function Finish: TBytes;    { encoding: flushes and returns the output }
  end;

  TCtxTable = record
    Bits: Integer;
    S: array of LongWord;       { probability (low 16 bits) and hit count (high 16) }
    procedure Init(aBits: Integer);
    function Slot(h: LongWord): SizeInt;
    function P(i: SizeInt): Integer;
    procedure Update(i: SizeInt; bit: Integer);
  end;

  TMixer = record
    NIn, NSets: Integer;
    W: array of Integer;        { NSets * NIn, 16.16 fixed point }
    X: array[0..CM_MAX_INPUTS - 1] of Integer;   { stretched inputs }
    Cnt: Integer;
    Sel: Integer;
    Pr: Integer;                { last output, 12 bits }
    procedure Init(aNIn, aNSets: Integer);
    procedure Add(st: Integer);
    function Mix(aSel: Integer): Integer;          { returns P(1) in 12 bits }
    procedure Update(bit: Integer);
  end;

  { Adaptive probability map: refines a probability given a small context. }
  TApm = record
    T: array of Word;
    Idx: SizeInt;
    procedure Init(n: Integer);
    function Refine(pr12, ctx: Integer): Integer;
    procedure Update(bit: Integer);
  end;

function Stretch(p12: Integer): Integer;     { ln(p/(1-p)), scaled by 256, p in 12 bits }
function Squash(d: Integer): Integer;        { inverse; returns 12 bits }
function Hash3(a, b, c: LongWord): LongWord;

var
  RateTab: array[0..255] of Integer;   { counter learning rate by hit count, in 1/65536 }
  StretchTab: array[0..4095] of SmallInt;
  SquashTab: array[-2047..2047] of SmallInt;

implementation



{ Squash by interpolation in a 33-point table: integers only, so every
  platform builds the same tables. }
function SquashCalc(d: Integer): Integer;
const
  T: array[0..32] of Integer = (1, 2, 3, 6, 10, 16, 27, 45, 73, 120, 194,
    310, 488, 747, 1101, 1546, 2047, 2549, 2994, 3348, 3607, 3785, 3901,
    3975, 4022, 4050, 4068, 4079, 4085, 4089, 4092, 4093, 4094);
var
  w, i: Integer;
begin
  if d > 2047 then Exit(4095);
  if d < -2047 then Exit(1);
  i := (d + 2048) shr 7;
  w := (d + 2048) and 127;
  Result := (T[i] * (128 - w) + T[i + 1] * w + 64) shr 7;
end;


function Squash(d: Integer): Integer;
begin
  if d > 2047 then d := 2047;
  if d < -2047 then d := -2047;
  Result := SquashTab[d];
end;

function Stretch(p12: Integer): Integer;
begin
  Result := StretchTab[p12];
end;

procedure InitTables;
var
  i, pi, j, v: Integer;
begin
  { stretch is the inverse of squash, found by search }
  for i := -2047 to 2047 do
    SquashTab[i] := SquashCalc(i);
  pi := 0;
  for i := -2047 to 2047 do
  begin
    v := SquashTab[i];
    for j := pi to v do
      StretchTab[j] := i;
    pi := v + 1;
  end;
  for j := pi to 4095 do
    StretchTab[j] := 2047;
  for i := 0 to 255 do
    RateTab[i] := 65536 div (i + 2);
end;

{ Hashing wraps around on purpose: overflow checks are off here only. }
{$push}{$Q-}{$R-}
function Hash3(a, b, c: LongWord): LongWord;
var
  h: LongWord;
begin
  h := a * 2654435761 + b * 2246822519 + c * 3266489917;
  h := h xor (h shr 15);
  h := h * 668265263;
  h := h xor (h shr 13);
  h := h * 2246822519;
  Result := h xor (h shr 16);
end;
{$pop}

{ ---- arithmetic coder ---- }

procedure TArith.InitEncode;
begin
  Encoding := True;
  X1 := 0;
  X2 := $FFFFFFFF;
  Buf := nil;
  SetLength(Buf, 4096);
  BufPos := 0;
end;

procedure TArith.InitDecode(const a: TBytes; first: SizeInt);
var
  i: Integer;
begin
  Encoding := False;
  X1 := 0;
  X2 := $FFFFFFFF;
  Buf := a;
  BufPos := first;
  X := 0;
  for i := 1 to 4 do
  begin
    X := (X shl 8);
    if BufPos < Length(Buf) then X := X or Buf[BufPos];
    Inc(BufPos);
  end;
end;

function TArith.Code(bit: Integer; p16: Integer): Integer;
var
  xmid: LongWord;
begin
  if p16 < 1 then p16 := 1;
  if p16 > 65535 then p16 := 65535;
  xmid := X1 + LongWord((QWord(X2 - X1) * LongWord(p16)) shr 16);
  if Encoding then
    Result := bit
  else if X <= xmid then
    Result := 1
  else
    Result := 0;
  if Result <> 0 then X2 := xmid else X1 := xmid + 1;
  while ((X1 xor X2) and $FF000000) = 0 do
  begin
    if Encoding then
    begin
      if BufPos >= Length(Buf) then SetLength(Buf, Length(Buf) * 2);
      Buf[BufPos] := X2 shr 24;
      Inc(BufPos);
    end
    else
    begin
      X := (X shl 8);
      if BufPos < Length(Buf) then X := X or Buf[BufPos];
      Inc(BufPos);
    end;
    X1 := X1 shl 8;
    X2 := (X2 shl 8) or 255;
  end;
end;

function TArith.Finish: TBytes;
var
  i: Integer;
begin
  { four bytes of X1 pin the final interval }
  for i := 0 to 3 do
  begin
    if BufPos >= Length(Buf) then SetLength(Buf, Length(Buf) * 2);
    Buf[BufPos] := (X1 shr (24 - 8 * i)) and $FF;
    Inc(BufPos);
  end;
  Result := Copy(Buf, 0, BufPos);
end;

{ ---- context tables ---- }

procedure TCtxTable.Init(aBits: Integer);
begin
  Bits := aBits;
  S := nil;
  SetLength(S, SizeInt(1) shl aBits);
  FillDWord(S[0], Length(S), 32768);
end;

function TCtxTable.Slot(h: LongWord): SizeInt;
begin
  Result := SizeInt(h shr (32 - Bits));
end;

function TCtxTable.P(i: SizeInt): Integer;
begin
  Result := S[i] and $FFFF;
end;

procedure TCtxTable.Update(i: SizeInt; bit: Integer);
var
  v: LongWord;
  pr, n: Integer;
begin
  v := S[i];
  pr := v and $FFFF;
  n := v shr 16;
  if bit <> 0 then
    pr := pr + (((65535 - pr) * RateTab[n]) shr 16)
  else
    pr := pr - ((pr * RateTab[n]) shr 16);
  if pr < 32 then pr := 32;
  if pr > 65503 then pr := 65503;
  if n < 127 then Inc(n);
  S[i] := LongWord(pr) or (LongWord(n) shl 16);
end;

{ ---- mixer ---- }

procedure TMixer.Init(aNIn, aNSets: Integer);
var
  i: Integer;
begin
  NIn := aNIn;
  NSets := aNSets;
  W := nil;
  SetLength(W, NIn * NSets);
  for i := 0 to High(W) do W[i] := 65536 div 4;
  Cnt := 0;
end;

procedure TMixer.Add(st: Integer);
begin
  X[Cnt] := st;
  Inc(Cnt);
end;

function TMixer.Mix(aSel: Integer): Integer;
var
  i: Integer;
  dot: Int64;
begin
  Sel := aSel * NIn;
  dot := 0;
  for i := 0 to Cnt - 1 do
    dot := dot + Int64(X[i]) * W[Sel + i];
  dot := SarInt64(dot, 16);
  if dot > 2047 then dot := 2047;
  if dot < -2047 then dot := -2047;
  Pr := Squash(Integer(dot));
  Result := Pr;
end;

procedure TMixer.Update(bit: Integer);
var
  err, i: Integer;
begin
  err := (bit shl 12) - Pr;
  for i := 0 to Cnt - 1 do
    W[Sel + i] := W[Sel + i] + Integer(SarInt64(Int64(X[i]) * err * MIX_RATE, 14));
  Cnt := 0;
end;

{ ---- APM ---- }

procedure TApm.Init(n: Integer);
var
  i, j: Integer;
begin
  T := nil;
  SetLength(T, n * 33);
  for i := 0 to n - 1 do
    for j := 0 to 32 do
      T[i * 33 + j] := Squash((j - 16) * 128) * 16;
  Idx := 0;
end;

function TApm.Refine(pr12, ctx: Integer): Integer;
var
  s, lo, w: Integer;
begin
  s := Stretch(pr12) + 2048;          { 0..4095 }
  lo := s shr 7;                      { 0..31 }
  w := s and 127;
  Idx := ctx * 33 + lo;
  Result := (T[Idx] * (128 - w) + T[Idx + 1] * w) shr 11;
  if w >= 64 then Inc(Idx);
  if Result < 1 then Result := 1;
  if Result > 4095 then Result := 4095;
end;

procedure TApm.Update(bit: Integer);
var
  g: Integer;
begin
  g := (bit shl 16) + (bit shl 5) - bit - bit;
  T[Idx] := T[Idx] + ((g - T[Idx]) div 64);
end;

initialization
  InitTables;
end.
