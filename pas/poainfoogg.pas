{ The info provider (poainfo) of Ogg files, after PJA's per-format
  providers (pas/pjainfojpeg.pas) and PMPA's (pas/pmpainfompeg.pas).

  From the container alone (poaogg): the pages and the gaps between them
  (bytes that are no page: junk, a tag in front, a cut page), the pages
  whose CRC does not match, and each logical stream with its codec (from
  its first packet), pages, complete packets, payload bytes and whether its
  last packet is left open (a cut stream). A chained file shows each link's
  streams in order. Nothing of what a packet holds is shown: no audio, no
  comment header text (titles, artists), only counts and sizes. }
unit poainfoogg;

{$I poa.inc}
{$ifopt R-}{$fatal poainfoogg: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poainfoogg: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, poainfo;

function ProbeOgg(const d: TBytes): Boolean;
procedure DescribeOgg(const d: TBytes; n: TInfoNode);

implementation

uses poaogg;

const
  MAX_LISTED_STREAMS = 100;
  MAX_LISTED_GAPS = 100;

function ProbeOgg(const d: TBytes): Boolean;
var sc: TOggScan;
begin
  OggScan(d, sc);
  Result := Length(sc.Pages) > 0;
end;

procedure DescribeOgg(const d: TBytes; n: TInfoNode);
var sc: TOggScan; ss: TOggStreams; k, bad, bos: SizeInt; gapBytes, pageBytes: Int64; l, o, pr: TInfoNode;
    line: string;
begin
  OggScan(d, sc);
  ss := OggStreams(d, sc);
  n.Str('format', 'Ogg');
  n.Num('size', Length(d));
  bad := 0; bos := 0; pageBytes := 0;
  for k := 0 to High(sc.Pages) do begin
    if not sc.Pages[k].CrcOk then Inc(bad);
    if sc.Pages[k].HType and OGG_FLAG_BOS <> 0 then Inc(bos);
    Inc(pageBytes, sc.Pages[k].Size);
  end;
  gapBytes := 0;
  for k := 0 to High(sc.Gaps) do Inc(gapBytes, sc.Gaps[k].Len);
  n.Num('pages', Length(sc.Pages));
  n.Num('page_bytes', pageBytes);
  n.Num('bad_crc_pages', bad);
  n.Num('gaps', Length(sc.Gaps));
  n.Num('gap_bytes', gapBytes);
  n.Num('streams', Length(ss));
  l := n.List('stream_list');
  for k := 0 to High(ss) do begin
    if k >= MAX_LISTED_STREAMS then Break;
    o := l.Obj;
    o.Str('serial', '0x' + LowerCase(IntToHex(ss[k].Serial, 8)));
    o.Str('codec', OggCodecName(ss[k].Codec));
    o.Num('pages', ss[k].Pages);
    o.Num('packets', ss[k].Packets);
    o.Num('bytes', ss[k].Bytes);
    o.Num('bad_crc_pages', ss[k].BadCrc);
    o.Bool('unterminated', ss[k].Unterminated);
    line := 'serial ' + o.Find('serial').value + ': ' + OggCodecName(ss[k].Codec) + ', ' +
            IntToStr(ss[k].Pages) + ' pages, ' + IntToStr(ss[k].Packets) + ' packets, ' +
            IntToStr(ss[k].Bytes) + ' B';
    if ss[k].BadCrc > 0 then line := line + ', ' + IntToStr(ss[k].BadCrc) + ' bad CRCs';
    if ss[k].Unterminated then line := line + ', last packet left open';
    o.line := line;
  end;
  if Length(ss) > MAX_LISTED_STREAMS then n.Num('streams_not_listed', Length(ss) - MAX_LISTED_STREAMS);
  if Length(sc.Gaps) > 0 then begin
    l := n.List('gap_list');
    for k := 0 to High(sc.Gaps) do begin
      if k >= MAX_LISTED_GAPS then Break;
      o := l.Obj;
      o.Num('offset', sc.Gaps[k].Pos);
      o.Num('length', sc.Gaps[k].Len);
      o.line := 'at ' + IntToStr(sc.Gaps[k].Pos) + ', ' + IntToStr(sc.Gaps[k].Len) + ' B';
    end;
    if Length(sc.Gaps) > MAX_LISTED_GAPS then n.Num('gaps_not_listed', Length(sc.Gaps) - MAX_LISTED_GAPS);
  end;
  { what does not fit the container's rules: said, not fatal (POA keeps it) }
  pr := n.List('problems');
  if bad > 0 then pr.Add(TInfoNode.Create(ikText)).value := IntToStr(bad) + ' page(s) whose CRC does not match';
  if gapBytes > 0 then pr.Add(TInfoNode.Create(ikText)).value := IntToStr(gapBytes) + ' B outside any page';
  for k := 0 to High(ss) do
    if ss[k].Unterminated then begin
      pr.Add(TInfoNode.Create(ikText)).value := 'a stream whose last packet never ends (a cut file?)';
      Break;
    end;
  if bos > 1 then n.Num('beginnings_of_stream', bos);
end;

initialization
  RegisterInfoProvider('ogg', @ProbeOgg, @DescribeOgg);
end.
