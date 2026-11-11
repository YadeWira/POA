{ The Ogg container (RFC 3533): pages, their CRC, logical streams and the
  packets they carry, and the exact way back from those parts to the bytes.

  A file is read as a sequence of pages and gaps. A page starts with
  "OggS", version 0, and fits entirely in the file. Anything else between
  pages (junk, a truncated page, an ID3 tag in front) is a gap and goes
  through as bytes. A page whose CRC does not match is still a page: its
  stored CRC is kept, never recomputed, so it comes back as it was.

  OggWritePage rebuilds one page from its fields and its payload. For every
  page of a scan, writing it back gives exactly the original bytes; the
  test in pas/tests/test_ogg.pas checks this on every file it is given. }
unit poaogg;

{$I poa.inc}
{$ifopt R-}{$fatal poaogg: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poaogg: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

const
  OGG_HDR = 27;                 { fixed part of a page header }
  OGG_MAX_SEG = 255;
  OGG_FLAG_CONT = $01;          { first packet continues from the previous page }
  OGG_FLAG_BOS = $02;
  OGG_FLAG_EOS = $04;

type
  TOggPage = record
    Pos: SizeInt;               { offset of "OggS" in the file }
    HType: Byte;                { flags: continued, BOS, EOS (other bits kept as is) }
    Granule: QWord;
    Serial, SeqNo, Crc: LongWord;
    NSeg: Integer;
    Lacing: array[0..OGG_MAX_SEG - 1] of Byte;
    DataPos, DataLen: SizeInt;
    CrcOk: Boolean;
    function Size: SizeInt;
  end;

  TOggGap = record
    Pos, Len: SizeInt;
  end;

  { One item of the file, in order: a page or a gap. }
  TOggItem = record
    IsPage: Boolean;
    Index: SizeInt;             { into Pages or Gaps }
  end;

  TOggScan = record
    Pages: array of TOggPage;
    Gaps: array of TOggGap;
    Items: array of TOggItem;
    procedure Clear;
  end;

  TOggCodec = (ocUnknown, ocVorbis, ocOpus, ocFlac, ocSpeex, ocTheora,
               ocSkeleton, ocCelt, ocDaala, ocKate, ocDirac, ocPcm);

  TOggStream = record
    Serial: LongWord;
    Codec: TOggCodec;
    Pages: SizeInt;
    Packets: SizeInt;           { complete packets }
    Bytes: SizeInt;             { payload bytes }
    BadCrc: SizeInt;
    Unterminated: Boolean;      { last packet never ends (truncated stream) }
  end;
  TOggStreams = array of TOggStream;

function OggCrc(const a: TBytes; aFirst, aLen: SizeInt; aCrc: LongWord = 0): LongWord;

{ Splits a whole file into pages and gaps. Never fails: a file with no
  page at all is a single gap. }
procedure OggScan(const a: TBytes; out s: TOggScan);

{ The page's bytes, rebuilt from its fields and the payload a[DataPos..]. }
function OggWritePage(const p: TOggPage; const a: TBytes): TBytes;

{ The logical streams of a scan: packets reassembled, codec identified by
  the first packet. }
function OggStreams(const a: TBytes; const s: TOggScan): TOggStreams;

function OggCodecName(c: TOggCodec): string;

implementation

var
  CrcTab: array[0..255] of LongWord;

procedure InitCrc;
var
  i, j: Integer;
  r: LongWord;
begin
  { Ogg's CRC-32: polynomial 04C11DB7, not reflected, initial value 0, no
    final xor. }
  for i := 0 to 255 do
  begin
    r := LongWord(i) shl 24;
    for j := 1 to 8 do
      if (r and $80000000) <> 0 then
        r := (r shl 1) xor $04C11DB7
      else
        r := r shl 1;
    CrcTab[i] := r;
  end;
end;

function OggCrc(const a: TBytes; aFirst, aLen: SizeInt; aCrc: LongWord): LongWord;
var
  i: SizeInt;
begin
  Result := aCrc;
  for i := aFirst to aFirst + aLen - 1 do
    Result := (Result shl 8) xor CrcTab[((Result shr 24) xor a[i]) and $FF];
end;

function TOggPage.Size: SizeInt;
begin
  Result := OGG_HDR + NSeg + DataLen;
end;

procedure TOggScan.Clear;
begin
  Pages := nil;
  Gaps := nil;
  Items := nil;
end;

function Rd32(const a: TBytes; p: SizeInt): LongWord;
begin
  Result := LongWord(a[p]) or (LongWord(a[p + 1]) shl 8) or
            (LongWord(a[p + 2]) shl 16) or (LongWord(a[p + 3]) shl 24);
end;

function Rd64(const a: TBytes; p: SizeInt): QWord;
begin
  Result := QWord(Rd32(a, p)) or (QWord(Rd32(a, p + 4)) shl 32);
end;

procedure Wr32(var a: TBytes; p: SizeInt; v: LongWord);
begin
  a[p] := v and $FF;
  a[p + 1] := (v shr 8) and $FF;
  a[p + 2] := (v shr 16) and $FF;
  a[p + 3] := (v shr 24) and $FF;
end;

{ The page at p, when there is a whole one there. The CRC field counts as
  zero when the CRC is computed. }
function TryPage(const a: TBytes; p: SizeInt; out pg: TOggPage): Boolean;
var
  n, i: SizeInt;
  t: TBytes;
begin
  Result := False;
  n := Length(a);
  if n - p < OGG_HDR then Exit;
  if (a[p] <> Ord('O')) or (a[p + 1] <> Ord('g')) or (a[p + 2] <> Ord('g')) or
     (a[p + 3] <> Ord('S')) or (a[p + 4] <> 0) then Exit;
  pg.Pos := p;
  pg.HType := a[p + 5];
  pg.Granule := Rd64(a, p + 6);
  pg.Serial := Rd32(a, p + 14);
  pg.SeqNo := Rd32(a, p + 18);
  pg.Crc := Rd32(a, p + 22);
  pg.NSeg := a[p + 26];
  if n - p < OGG_HDR + pg.NSeg then Exit;
  pg.DataLen := 0;
  for i := 0 to pg.NSeg - 1 do
  begin
    pg.Lacing[i] := a[p + OGG_HDR + i];
    Inc(pg.DataLen, pg.Lacing[i]);
  end;
  pg.DataPos := p + OGG_HDR + pg.NSeg;
  if n - pg.DataPos < pg.DataLen then Exit;
  SetLength(t, OGG_HDR + pg.NSeg);
  Move(a[p], t[0], Length(t));
  Wr32(t, 22, 0);
  pg.CrcOk := OggCrc(a, pg.DataPos, pg.DataLen, OggCrc(t, 0, Length(t))) = pg.Crc;
  Result := True;
end;

procedure OggScan(const a: TBytes; out s: TOggScan);
var
  p, gapStart, n: SizeInt;
  pg: TOggPage;

  procedure AddItem(isPage: Boolean; idx: SizeInt);
  begin
    SetLength(s.Items, Length(s.Items) + 1);
    s.Items[High(s.Items)].IsPage := isPage;
    s.Items[High(s.Items)].Index := idx;
  end;

  procedure FlushGap;
  begin
    if p > gapStart then
    begin
      SetLength(s.Gaps, Length(s.Gaps) + 1);
      s.Gaps[High(s.Gaps)].Pos := gapStart;
      s.Gaps[High(s.Gaps)].Len := p - gapStart;
      AddItem(False, High(s.Gaps));
    end;
  end;

begin
  s.Clear;
  n := Length(a);
  p := 0;
  gapStart := 0;
  while p < n do
    if TryPage(a, p, pg) then
    begin
      FlushGap;
      SetLength(s.Pages, Length(s.Pages) + 1);
      s.Pages[High(s.Pages)] := pg;
      AddItem(True, High(s.Pages));
      Inc(p, pg.Size);
      gapStart := p;
    end
    else
      Inc(p);
  FlushGap;
end;

function OggWritePage(const p: TOggPage; const a: TBytes): TBytes;
var
  i: Integer;
  crc: LongWord;
begin
  Result := nil;
  SetLength(Result, p.Size);
  Result[0] := Ord('O'); Result[1] := Ord('g'); Result[2] := Ord('g'); Result[3] := Ord('S');
  Result[4] := 0;
  Result[5] := p.HType;
  Wr32(Result, 6, LongWord(p.Granule and $FFFFFFFF));
  Wr32(Result, 10, LongWord(p.Granule shr 32));
  Wr32(Result, 14, p.Serial);
  Wr32(Result, 18, p.SeqNo);
  Wr32(Result, 22, 0);
  Result[26] := p.NSeg;
  for i := 0 to p.NSeg - 1 do
    Result[OGG_HDR + i] := p.Lacing[i];
  if p.DataLen > 0 then
    Move(a[p.DataPos], Result[OGG_HDR + p.NSeg], p.DataLen);
  if p.CrcOk then
    crc := OggCrc(Result, 0, Length(Result))
  else
    crc := p.Crc;
  Wr32(Result, 22, crc);
end;

function Identify(const pk: TBytes): TOggCodec;

  function Starts(const sig: string; ofs: Integer = 0): Boolean;
  var
    i: Integer;
  begin
    Result := Length(pk) >= ofs + Length(sig);
    if Result then
      for i := 1 to Length(sig) do
        if pk[ofs + i - 1] <> Ord(sig[i]) then Exit(False);
  end;

begin
  Result := ocUnknown;
  if Length(pk) = 0 then Exit;
  if (pk[0] = 1) and Starts('vorbis', 1) then Result := ocVorbis
  else if Starts('OpusHead') then Result := ocOpus
  else if (pk[0] = $7F) and Starts('FLAC', 1) then Result := ocFlac
  else if Starts('Speex   ') then Result := ocSpeex
  else if (pk[0] = $80) and Starts('theora', 1) then Result := ocTheora
  else if Starts('fishead'#0) or Starts('fisbone'#0) then Result := ocSkeleton
  else if Starts('CELT    ') then Result := ocCelt
  else if (pk[0] = $80) and Starts('daala', 1) then Result := ocDaala
  else if (pk[0] = $80) and Starts('kate'#0#0#0, 1) then Result := ocKate
  else if Starts('BBCD'#0) then Result := ocDirac
  else if Starts('PCM     ') then Result := ocPcm;
end;

function OggCodecName(c: TOggCodec): string;
const
  N: array[TOggCodec] of string = ('unknown', 'Vorbis', 'Opus', 'FLAC',
    'Speex', 'Theora', 'Skeleton', 'CELT', 'Daala', 'Kate', 'Dirac', 'PCM');
begin
  Result := N[c];
end;

function OggStreams(const a: TBytes; const s: TOggScan): TOggStreams;
var
  i, j, k, seg: SizeInt;
  cur: array of TBytes;         { the packet being assembled, per stream }
  open: array of Boolean;       { a packet is open (last lacing was 255) }
  pg: ^TOggPage;
  pos: SizeInt;
begin
  Result := nil;
  cur := nil;
  open := nil;
  for i := 0 to High(s.Pages) do
  begin
    pg := @s.Pages[i];
    k := -1;
    for j := 0 to High(Result) do
      if Result[j].Serial = pg^.Serial then begin k := j; Break; end;
    if k < 0 then
    begin
      k := Length(Result);
      SetLength(Result, k + 1);
      SetLength(cur, k + 1);
      SetLength(open, k + 1);
      FillChar(Result[k], SizeOf(TOggStream), 0);
      Result[k].Serial := pg^.Serial;
      cur[k] := nil;
      open[k] := False;
    end;
    Inc(Result[k].Pages);
    Inc(Result[k].Bytes, pg^.DataLen);
    if not pg^.CrcOk then Inc(Result[k].BadCrc);
    pos := pg^.DataPos;
    for seg := 0 to pg^.NSeg - 1 do
    begin
      if pg^.Lacing[seg] > 0 then
      begin
        j := Length(cur[k]);
        SetLength(cur[k], j + pg^.Lacing[seg]);
        Move(a[pos], cur[k][j], pg^.Lacing[seg]);
        Inc(pos, pg^.Lacing[seg]);
      end;
      if pg^.Lacing[seg] < 255 then
      begin
        if (Result[k].Packets = 0) then
          Result[k].Codec := Identify(cur[k]);
        Inc(Result[k].Packets);
        cur[k] := nil;
        open[k] := False;
      end
      else
        open[k] := True;
    end;
  end;
  for k := 0 to High(Result) do
    Result[k].Unterminated := open[k];
end;

initialization
  InitCrc;
end.
