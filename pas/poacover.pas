{ Cover art in Ogg comment headers.

  Vorbis and Opus keep tags as a comment list (the Vorbis comment header:
  a vendor string, then "NAME=value" entries, each with its 32-bit
  little-endian length). A picture is the entry METADATA_BLOCK_PICTURE,
  whose value is a FLAC PICTURE metadata block in base64: picture type,
  MIME type, description, width, height, depth, colours, then the image
  (a JPEG or a PNG, mostly).

  CoverFind lists the pictures of a comment packet that come back exactly:
  their base64 is canonical (standard alphabet, padded, no line breaks:
  encoding the decoded block again gives the same text) and the block's
  fields add up to its length. Anything else stays in the packet as it is.
  The packet without those values (Strip) and the blocks give the packet
  back (Splice). }
unit poacover;

{$I poa.inc}
{$ifopt R-}{$fatal poacover: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poacover: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils;

type
  TCover = record
    Pos: SizeInt;           { where the base64 value starts in the packet }
    Len: SizeInt;           { its length in the packet }
    Block: TBytes;          { the PICTURE block, decoded }
    DataPos: SizeInt;       { where the image starts in Block }
  end;
  TCovers = array of TCover;

{ The comment entries of a Vorbis (03 "vorbis") or Opus ("OpusTags")
  comment packet that are pictures POA can take apart. }
function CoverFind(const pk: TBytes): TCovers;

{ The packet without the covers' base64 values. }
function CoverStrip(const pk: TBytes; const c: TCovers): TBytes;

{ The packet back: each block's base64 inserted where it was. Positions are
  the original packet's, in increasing order. }
function CoverSplice(const stripped: TBytes; const c: TCovers): TBytes;

function Base64Encode(const b: TBytes): TBytes;
{ False unless s is canonical base64 (encoding the result gives s again). }
function Base64Decode(const s: TBytes; first, len: SizeInt; out b: TBytes): Boolean;

{ The PICTURE block's image offset, or -1 if its fields do not add up to
  exactly its length. }
function PictureDataPos(const b: TBytes): SizeInt;

implementation

const
  B64: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  KEY = 'METADATA_BLOCK_PICTURE=';

var
  B64Rev: array[0..255] of SmallInt;

function Base64Encode(const b: TBytes): TBytes;
var
  i, o, n: SizeInt;
  v: LongWord;
begin
  n := Length(b);
  Result := nil;
  SetLength(Result, ((n + 2) div 3) * 4);
  i := 0;
  o := 0;
  while i + 2 < n do
  begin
    v := (LongWord(b[i]) shl 16) or (LongWord(b[i + 1]) shl 8) or b[i + 2];
    Result[o] := Ord(B64[1 + (v shr 18) and 63]);
    Result[o + 1] := Ord(B64[1 + (v shr 12) and 63]);
    Result[o + 2] := Ord(B64[1 + (v shr 6) and 63]);
    Result[o + 3] := Ord(B64[1 + v and 63]);
    Inc(i, 3);
    Inc(o, 4);
  end;
  if n - i = 1 then
  begin
    v := LongWord(b[i]) shl 16;
    Result[o] := Ord(B64[1 + (v shr 18) and 63]);
    Result[o + 1] := Ord(B64[1 + (v shr 12) and 63]);
    Result[o + 2] := Ord('=');
    Result[o + 3] := Ord('=');
  end
  else if n - i = 2 then
  begin
    v := (LongWord(b[i]) shl 16) or (LongWord(b[i + 1]) shl 8);
    Result[o] := Ord(B64[1 + (v shr 18) and 63]);
    Result[o + 1] := Ord(B64[1 + (v shr 12) and 63]);
    Result[o + 2] := Ord(B64[1 + (v shr 6) and 63]);
    Result[o + 3] := Ord('=');
  end;
end;

function Base64Decode(const s: TBytes; first, len: SizeInt; out b: TBytes): Boolean;
var
  i, o, pad, n: SizeInt;
  v: LongWord;
  c: Integer;
  k: Integer;
  e: TBytes;
begin
  Result := False;
  b := nil;
  if (len = 0) or (len mod 4 <> 0) then Exit;
  pad := 0;
  if s[first + len - 1] = Ord('=') then Inc(pad);
  if s[first + len - 2] = Ord('=') then Inc(pad);
  n := (len div 4) * 3 - pad;
  SetLength(b, n);
  o := 0;
  i := first;
  while i < first + len do
  begin
    v := 0;
    for k := 0 to 3 do
    begin
      if s[i + k] = Ord('=') then
      begin
        if i + 4 <> first + len then Exit;    { padding only at the very end }
        c := 0;
      end
      else
      begin
        c := B64Rev[s[i + k]];
        if c < 0 then Exit;
      end;
      v := (v shl 6) or LongWord(c);
    end;
    if o < n then b[o] := (v shr 16) and $FF;
    if o + 1 < n then b[o + 1] := (v shr 8) and $FF;
    if o + 2 < n then b[o + 2] := v and $FF;
    Inc(o, 3);
    Inc(i, 4);
  end;
  { canonical: the unused bits are zero, so encoding again is the same }
  e := Base64Encode(b);
  if Length(e) <> len then Exit;
  Result := CompareMem(@e[0], @s[first], len);
end;

function Rd32BE(const b: TBytes; p: SizeInt): QWord;
begin
  Result := (QWord(b[p]) shl 24) or (QWord(b[p + 1]) shl 16) or (QWord(b[p + 2]) shl 8) or b[p + 3];
end;

function Rd32LE(const b: TBytes; p: SizeInt): QWord;
begin
  Result := QWord(b[p]) or (QWord(b[p + 1]) shl 8) or (QWord(b[p + 2]) shl 16) or (QWord(b[p + 3]) shl 24);
end;

function PictureDataPos(const b: TBytes): SizeInt;
var
  p, n: SizeInt;
  l: QWord;
begin
  Result := -1;
  n := Length(b);
  p := 4;                                   { picture type }
  if p + 4 > n then Exit;
  l := Rd32BE(b, p); Inc(p, 4);             { MIME }
  if l > QWord(n - p) then Exit;
  Inc(p, SizeInt(l));
  if p + 4 > n then Exit;
  l := Rd32BE(b, p); Inc(p, 4);             { description }
  if l > QWord(n - p) then Exit;
  Inc(p, SizeInt(l));
  if p + 20 > n then Exit;                  { width, height, depth, colours, data length }
  l := Rd32BE(b, p + 16);
  Inc(p, 20);
  if l <> QWord(n - p) then Exit;
  Result := p;
end;

function CoverFind(const pk: TBytes): TCovers;
var
  p, n, i, k, vpos: SizeInt;
  cnt, l: QWord;
  c: TCover;
  ok: Boolean;
begin
  Result := nil;
  n := Length(pk);
  if (n >= 7) and (pk[0] = 3) and (pk[1] = Ord('v')) and (pk[2] = Ord('o')) and (pk[3] = Ord('r')) and
     (pk[4] = Ord('b')) and (pk[5] = Ord('i')) and (pk[6] = Ord('s')) then
    p := 7
  else if (n >= 8) and (pk[0] = Ord('O')) and (pk[1] = Ord('p')) and (pk[2] = Ord('u')) and
          (pk[3] = Ord('s')) and (pk[4] = Ord('T')) and (pk[5] = Ord('a')) and (pk[6] = Ord('g')) and
          (pk[7] = Ord('s')) then
    p := 8
  else
    Exit;
  if p + 4 > n then Exit;
  l := Rd32LE(pk, p); Inc(p, 4);            { vendor }
  if l > QWord(n - p) then Exit;
  Inc(p, SizeInt(l));
  if p + 4 > n then Exit;
  cnt := Rd32LE(pk, p); Inc(p, 4);
  while (cnt > 0) and (p + 4 <= n) do
  begin
    Dec(cnt);
    l := Rd32LE(pk, p); Inc(p, 4);
    if l > QWord(n - p) then Exit;
    { NAME= is case-insensitive in the specification }
    ok := l > Length(KEY);
    if ok then
      for k := 1 to Length(KEY) do
        if UpCase(Chr(pk[p + k - 1])) <> KEY[k] then begin ok := False; Break; end;
    if ok then
    begin
      vpos := p + Length(KEY);
      c := Default(TCover);
      c.Pos := vpos;
      c.Len := SizeInt(l) - Length(KEY);
      if Base64Decode(pk, vpos, c.Len, c.Block) then
      begin
        c.DataPos := PictureDataPos(c.Block);
        if c.DataPos >= 0 then
        begin
          i := Length(Result);
          SetLength(Result, i + 1);
          Result[i] := c;
        end;
      end;
    end;
    Inc(p, SizeInt(l));
  end;
end;

function CoverStrip(const pk: TBytes; const c: TCovers): TBytes;
var
  i, p, o: SizeInt;
begin
  Result := nil;
  SetLength(Result, Length(pk));
  p := 0;
  o := 0;
  for i := 0 to High(c) do
  begin
    if c[i].Pos > p then Move(pk[p], Result[o], c[i].Pos - p);
    Inc(o, c[i].Pos - p);
    p := c[i].Pos + c[i].Len;
  end;
  if Length(pk) > p then Move(pk[p], Result[o], Length(pk) - p);
  Inc(o, Length(pk) - p);
  SetLength(Result, o);
end;

function CoverSplice(const stripped: TBytes; const c: TCovers): TBytes;
var
  i, s, o, take: SizeInt;
  e: TBytes;
begin
  Result := nil;
  o := 0;
  s := 0;
  for i := 0 to High(c) do
  begin
    { c[i].Pos is in the original packet: the stripped bytes before it }
    take := c[i].Pos - o;
    if (take < 0) or (s + take > Length(stripped)) then
      raise Exception.Create('cover: position out of the packet');
    e := Base64Encode(c[i].Block);
    SetLength(Result, o + take + Length(e));
    if take > 0 then Move(stripped[s], Result[o], take);
    Inc(s, take);
    Inc(o, take);
    if Length(e) > 0 then Move(e[0], Result[o], Length(e));
    Inc(o, Length(e));
  end;
  SetLength(Result, o + Length(stripped) - s);
  if Length(stripped) > s then Move(stripped[s], Result[o], Length(stripped) - s);
end;

procedure InitRev;
var
  i: Integer;
begin
  for i := 0 to 255 do B64Rev[i] := -1;
  for i := 1 to 64 do B64Rev[Ord(B64[i])] := i - 1;
end;

initialization
  InitRev;
end.
