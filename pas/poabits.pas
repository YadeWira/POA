{ Bit packing as Vorbis does it: within each byte the first bit is the
  least significant one, and a field of n bits is read least significant
  bit first. }
unit poabits;

{$I poa.inc}
{$ifopt R-}{$fatal poabits: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poabits: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

type
  { Reads from a[First..First+Len-1]. Reading past the end does not fail:
    it sets Eop and returns the bits that were there (missing ones as 0). }
  TBitReader = record
    Data: TBytes;
    First, Len: SizeInt;
    Pos: SizeInt;               { in bits, from First }
    Eop: Boolean;
    procedure Init(const a: TBytes; aFirst, aLen: SizeInt);
    function Bit: LongWord;
    function Read(n: Integer): LongWord;    { n <= 32 }
    function BitsLeft: SizeInt;
  end;

  TBitWriter = record
    Data: TBytes;
    Pos: SizeInt;               { in bits }
    procedure Init;
    procedure Bit(b: LongWord);
    procedure Write(v: LongWord; n: Integer);
    function Bytes: TBytes;     { the bytes written, last one zero-padded }
  end;

function ILog(v: LongWord): Integer;

implementation

function ILog(v: LongWord): Integer;
begin
  Result := 0;
  while v > 0 do
  begin
    Inc(Result);
    v := v shr 1;
  end;
end;

procedure TBitReader.Init(const a: TBytes; aFirst, aLen: SizeInt);
begin
  Data := a;
  First := aFirst;
  Len := aLen;
  Pos := 0;
  Eop := False;
end;

function TBitReader.Bit: LongWord;
begin
  if Pos >= Len * 8 then
  begin
    Eop := True;
    Exit(0);
  end;
  Result := (Data[First + Pos shr 3] shr (Pos and 7)) and 1;
  Inc(Pos);
end;

function TBitReader.Read(n: Integer): LongWord;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to n - 1 do
    Result := Result or (Bit shl i);
end;

function TBitReader.BitsLeft: SizeInt;
begin
  Result := Len * 8 - Pos;
  if Result < 0 then Result := 0;
end;

procedure TBitWriter.Init;
begin
  Data := nil;
  SetLength(Data, 64);
  FillChar(Data[0], Length(Data), 0);
  Pos := 0;
end;

procedure TBitWriter.Bit(b: LongWord);
var
  old: SizeInt;
begin
  if Pos shr 3 >= Length(Data) then
  begin
    old := Length(Data);
    SetLength(Data, old * 2);
    FillChar(Data[old], old, 0);
  end;
  if (b and 1) <> 0 then
    Data[Pos shr 3] := Data[Pos shr 3] or (1 shl (Pos and 7));
  Inc(Pos);
end;

procedure TBitWriter.Write(v: LongWord; n: Integer);
var
  i: Integer;
begin
  for i := 0 to n - 1 do
    Bit((v shr i) and 1);
end;

function TBitWriter.Bytes: TBytes;
begin
  Result := Copy(Data, 0, (Pos + 7) shr 3);
end;

end.
