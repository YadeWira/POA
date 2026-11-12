{ Small models for what is not audio: numbers, flags and bytes. }
unit poaside;

{$I poa.inc}
{ POA_FAST: the release build of the model, without range and overflow
  checks (every table index here is masked to the table's size). The test
  builds keep them. }
{$ifdef POA_FAST}
  {$R-}{$Q-}
{$else}
  {$ifopt R-}{$fatal poaside: range checks ($R+) are mandatory}{$endif}
  {$ifopt Q-}{$fatal poaside: overflow checks ($Q+) are mandatory}{$endif}
{$endif}

interface

uses SysUtils, poacm;

type
  EPoaFormat = class(Exception);

  TSideModels = class
    Num: TCtxTable;
    Flag: TCtxTable;
    ByteT: array[0..3] of TCtxTable;
    ByteMx: TMixer;
    C1, C2, C3: LongWord;
    constructor Create(tabBits: Integer = 20);
    function CodeFlag(var ac: TArith; bit, ctx: Integer): Integer;
    function CodeNumBit(var ac: TArith; bit: Integer; h: LongWord): Integer;
    function CodeNum(var ac: TArith; v: QWord; ctx: Integer): QWord;
    function CodeByte(var ac: TArith; b, salt: Integer): Integer;
    procedure CodeBytes(var ac: TArith; var d: TBytes; n: SizeInt; salt: Integer);
  end;


function BitLength(v: QWord): Integer;

var
  Trace: Boolean = False;

implementation


constructor TSideModels.Create(tabBits: Integer);
var
  i: Integer;
begin
  inherited Create;
  Num.Init(16);
  Flag.Init(12);
  if tabBits > 20 then tabBits := 20;
  for i := 0 to 3 do ByteT[i].Init(tabBits);
  ByteMx.Init(5, 256);
  C1 := 0; C2 := 0; C3 := 0;
end;

function TSideModels.CodeFlag(var ac: TArith; bit, ctx: Integer): Integer;
var
  s: SizeInt;
begin
  s := ctx and ((1 shl 12) - 1);
  Result := ac.Code(bit, Flag.P(s));
  Flag.Update(s, Result);
  if Trace then WriteLn(StdErr, 'F ', ctx, ' ', Result);
end;

function BitLength(v: QWord): Integer;
begin
  Result := 0;
  while v <> 0 do
  begin
    Inc(Result);
    v := v shr 1;
  end;
end;

{ The bit length (0..64) through a 7-level tree, then the bits below the
  leading one, the top four of them with context.

  Written with one bit per call to CodeNumBit: FPC 3.2.2 at -O2 miscompiled
  the earlier single-loop version (tests/test_side failed at -O2 and -O3
  only, 11/11/2026). }
function TSideModels.CodeNumBit(var ac: TArith; bit: Integer; h: LongWord): Integer;
var
  s: SizeInt;
begin
  s := Num.Slot(h);
  Result := ac.Code(bit, Num.P(s));
  Num.Update(s, Result);
end;

function TSideModels.CodeNum(var ac: TArith; v: QWord; ctx: Integer): QWord;
var
  n, node, i, bit: Integer;
  r: QWord;
  h: LongWord;
begin
  if ac.Encoding then n := BitLength(v) else n := 0;
  node := 1;
  for i := 6 downto 0 do
  begin
    bit := CodeNumBit(ac, (n shr i) and 1, Hash3(LongWord(ctx), LongWord(node), 1));
    node := (node shl 1) or bit;
  end;
  n := node - 128;
  if n > 64 then raise EPoaFormat.Create('damaged stream (number)');
  r := 0;
  if n > 0 then
  begin
    r := 1;
    for i := n - 2 downto 0 do
    begin
      if ac.Encoding then bit := Integer((v shr i) and 1) else bit := 0;
      if i >= n - 5 then
        h := Hash3(LongWord(ctx), LongWord(n) or (LongWord(i) shl 8), LongWord(r and $FF) + 2)
      else
        h := Hash3(LongWord(ctx), LongWord(n) or (LongWord(i) shl 8), 3);
      bit := CodeNumBit(ac, bit, h);
      r := (r shl 1) or QWord(bit);
    end;
  end;
  Result := r;
  if Trace then WriteLn(StdErr, 'N ', ctx, ' ', r);
end;

function TSideModels.CodeByte(var ac: TArith; b, salt: Integer): Integer;
var
  node, i, bit, pr: Integer;
  h: array[0..3] of LongWord;
  sl: array[0..3] of SizeInt;
begin
  h[0] := Hash3(LongWord(salt), 0, 10);
  h[1] := Hash3(LongWord(salt), C1, 11);
  h[2] := Hash3(LongWord(salt), C1 or (C2 shl 8), 12);
  h[3] := Hash3(LongWord(salt), C1 or (C2 shl 8) or (C3 shl 16), 13);
  node := 1;
  for i := 7 downto 0 do
  begin
    bit := (b shr i) and 1;
    for pr := 0 to 3 do
    begin
      sl[pr] := ByteT[pr].Slot(Hash3(h[pr], LongWord(node), 14));
      ByteMx.Add(Stretch(ByteT[pr].P(sl[pr]) shr 4));
    end;
    ByteMx.Add(256);
    pr := ByteMx.Mix(node);
    bit := ac.Code(bit, pr * 16);
    for pr := 0 to 3 do ByteT[pr].Update(sl[pr], bit);
    ByteMx.Update(bit);
    node := (node shl 1) or bit;
  end;
  Result := node - 256;
  C3 := C2; C2 := C1; C1 := Result;
end;

procedure TSideModels.CodeBytes(var ac: TArith; var d: TBytes; n: SizeInt; salt: Integer);
var
  i: SizeInt;
begin
  if not ac.Encoding then
  begin
    d := nil;
    SetLength(d, n);
  end;
  C1 := 0; C2 := 0; C3 := 0;
  for i := 0 to n - 1 do
    d[i] := CodeByte(ac, d[i], salt);
end;

end.
