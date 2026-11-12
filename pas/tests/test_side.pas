{ The side models: random numbers, flags and bytes coded and decoded
  must come back the same. }
program test_side;

{$I ../poa.inc}

uses SysUtils, poacm, poaside;

const
  N = 20000;
var
  vals: array[0..N - 1] of QWord;
  ctxs, flags, bytes: array[0..N - 1] of Integer;
  m: TSideModels;
  ac: TArith;
  outb: TBytes;
  i, bad: Integer;
  v: QWord;
begin
  RandSeed := 12345;
  for i := 0 to N - 1 do
  begin
    case Random(4) of
      0: vals[i] := Random(10);
      1: vals[i] := Random(100000);
      2: vals[i] := (QWord(Random($7FFFFFFF)) shl 32) or QWord(Random($7FFFFFFF));
    else
      vals[i] := QWord($FFFFFFFFFFFFFFFF) - QWord(Random(5));
    end;
    ctxs[i] := Random(50);
    flags[i] := Random(2);
    bytes[i] := Random(256);
  end;
  m := TSideModels.Create;
  ac.InitEncode;
  for i := 0 to N - 1 do
  begin
    m.CodeNum(ac, vals[i], ctxs[i]);
    m.CodeFlag(ac, flags[i], ctxs[i]);
    m.CodeByte(ac, bytes[i], ctxs[i]);
  end;
  outb := ac.Finish;
  m.Free;
  m := TSideModels.Create;
  ac.InitDecode(outb, 0);
  bad := 0;
  for i := 0 to N - 1 do
  begin
    v := m.CodeNum(ac, 0, ctxs[i]);
    if v <> vals[i] then begin Inc(bad); if bad < 5 then WriteLn('num ', i, ': ', v, ' <> ', vals[i]); end;
    if m.CodeFlag(ac, 0, ctxs[i]) <> flags[i] then Inc(bad);
    if m.CodeByte(ac, 0, ctxs[i]) <> bytes[i] then Inc(bad);
  end;
  m.Free;
  WriteLn(Length(outb), ' bytes, ', bad, ' mismatches');
  if bad > 0 then Halt(1);
end.
