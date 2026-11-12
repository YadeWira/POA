{ Ported from PJA's pas/pjapack.pas via PMPA (pas/pmpapack.pas).

  A whole file to a .poa and back, for the command: the coder (poaformat)
  with the checks around it, timed by stage (poastage).

  Pack: refuse what is not Ogg (no Ogg page at all: POA is not a general
  compressor), code it, and, unless asked not to, decode the result and
  compare it with the input. A stream that does not come back is a bug in
  POA (EPoaVerify): nothing is written.
  Unpack: read the header, refuse a declared size above the caller's cap
  before decoding anything, decode with that size as the cap, then check
  the size and the BLAKE3-128. What comes out with ukOk is the original,
  byte for byte. }
unit poapack;

{$I poa.inc}
{$ifopt R-}{$fatal poapack: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poapack: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, poablake3, poaogg, poaformat, poastage, poalimits;

type
  { The header of a .poa (poaformat): what list and info show. }
  TPoaHeader = record
    format, flags: Byte;
    origSize: QWord;
    hash: THash16;
    stored: Boolean;
    payloadSize: SizeInt;
  end;

  TPackError = (
    ukOk,
    { not a .poa, or a header this version does not take (detail in why) }
    ukFormat,
    { no Ogg page in the input }
    ukNotOgg,
    { the coded stream is damaged (detail in why) }
    ukCodec,
    { the declared size is above the caller's cap }
    ukTooLarge,
    { decoded, but not to the declared length or hash: damaged }
    ukSizeMismatch, ukHashMismatch);

  TPackResult = record
    err: TPackError;
    why: string;
    { Pack: the original went in as it is (the coded stream would not have
      been smaller) }
    stored: Boolean;
    { Pack: what the coder saw }
    stats: TPoaStats;
    function Ok: Boolean;
    { the reason, in words }
    function Text: string;
  end;

  { the coded stream did not decode back to the input: a bug in POA }
  EPoaVerify = class(Exception);

{ The header of c: False, and why, when it is not a .poa this version
  reads. Checks the magic, the format, the flags and that the declared size
  is one the payload can hold (MAX_EXPANSION_RATIO); not the stream. }
function PoaOpen(const c: TBytes; out h: TPoaHeader; out why: string): Boolean;

{ The original file -> .poa. verify: decode the result and compare it
  with the input before handing it out (poa a --no-verify: False; x checks
  the hash in any case). Raises EPoaVerify when it does not come back. }
function Pack(const original: TBytes; out poa: TBytes; verify: Boolean = True): TPackResult;

{ .poa -> the original. maxOutput: the largest original accepted. With
  ukHashMismatch and ukSizeMismatch, `original` holds what was decoded (for
  x --keep-corrupt) and `expected` the hash it should have; with any other
  error it is empty. }
function Unpack(const poa: TBytes; maxOutput: QWord; out original: TBytes; out expected: THash16): TPackResult;

implementation

function TPackResult.Ok: Boolean;
begin Result := err = ukOk; end;

function TPackResult.Text: string;
begin
  case err of
    ukOk: Result := 'ok';
    ukNotOgg: Result := 'not an Ogg file (no Ogg page found)';
    ukTooLarge: Result := 'the original is larger than --max-output';
    ukSizeMismatch: Result := 'damaged: the size differs from the declared one';
    ukHashMismatch: Result := 'damaged: the BLAKE3-128 differs from the declared one';
  else
    Result := why;
  end;
end;

function PackFail(e: TPackError; const why: string = ''): TPackResult;
begin
  Result := Default(TPackResult);
  Result.err := e;
  Result.why := why;
end;

function Rd64(const b: TBytes; p: SizeInt): QWord;
var i: Integer;
begin
  Result := 0;
  for i := 7 downto 0 do Result := (Result shl 8) or b[p + i];
end;

function PoaOpen(const c: TBytes; out h: TPoaHeader; out why: string): Boolean;
var i: Integer;
begin
  h := Default(TPoaHeader);
  why := '';
  Result := False;
  if not PoaIsPoa(c) then begin why := 'not a .poa file'; Exit; end;
  h.format := c[4];
  h.flags := c[5];
  h.origSize := Rd64(c, 6);
  for i := 0 to 15 do h.hash[i] := c[14 + i];
  h.stored := (h.flags and POA_FLAG_STORED) <> 0;
  h.payloadSize := Length(c) - POA_HEADER;
  if h.format <> POA_FORMAT then begin
    why := 'a .poa of format ' + IntToStr(h.format) + ', which this version does not read (it reads ' +
           IntToStr(POA_FORMAT) + ')';
    Exit;
  end;
  if (h.flags and not POA_FLAG_STORED) <> 0 then begin why := 'damaged header (flags)'; Exit; end;
  if not h.stored then begin
    if h.payloadSize = 0 then begin why := 'damaged: no coded stream'; Exit; end;
    if h.origSize div MAX_EXPANSION_RATIO > QWord(h.payloadSize) then begin
      why := 'damaged header: a declared size its stream cannot hold'; Exit;
    end;
  end;
  Result := True;
end;

function SameBytes(const a, b: TBytes): Boolean;
begin
  Result := (Length(a) = Length(b)) and ((Length(a) = 0) or CompareMem(@a[0], @b[0], Length(a)));
end;

function Pack(const original: TBytes; out poa: TBytes; verify: Boolean): TPackResult;
var sc: TOggScan; back: TBytes;
begin
  poa := nil;
  Result := PackFail(ukOk);
  StageEnter(stParse);
  OggScan(original, sc);
  if Length(sc.Pages) = 0 then begin
    StageEnter(stNone);
    Exit(PackFail(ukNotOgg));
  end;
  sc.Clear;
  StageEnter(stEncode);
  poa := PoaEncode(original, Result.stats);
  Result.stored := (poa[5] and POA_FLAG_STORED) <> 0;
  if verify then begin
    StageEnter(stVerify);
    try
      back := PoaDecode(poa);
    except
      on e: EPoaFormat do
        raise EPoaVerify.Create('the coded stream does not decode back to the input: ' + e.Message);
    end;
    if not SameBytes(back, original) then
      raise EPoaVerify.Create('the coded stream decodes to other bytes than the input');
  end;
  StageEnter(stNone);
end;

function Unpack(const poa: TBytes; maxOutput: QWord; out original: TBytes; out expected: THash16): TPackResult;
var h: TPoaHeader; why: string; actual: THash16;
begin
  original := nil;
  FillChar(expected, SizeOf(expected), 0);
  Result := PackFail(ukOk);
  if not PoaOpen(poa, h, why) then Exit(PackFail(ukFormat, why));
  expected := h.hash;
  if h.origSize > maxOutput then Exit(PackFail(ukTooLarge));
  StageEnter(stDecode);
  try
    original := PoaDecodeData(poa, h.origSize);
  except
    on e: EPoaFormat do begin
      StageEnter(stNone);
      original := nil;
      Exit(PackFail(ukCodec, e.Message));
    end;
  end;
  StageEnter(stNone);
  if QWord(Length(original)) <> h.origSize then begin Result.err := ukSizeMismatch; Exit; end;
  StageEnter(stHash);
  actual := Blake3_128(original);
  StageEnter(stNone);
  if not CompareMem(@actual[0], @expected[0], SizeOf(THash16)) then Result.err := ukHashMismatch;
end;

end.
