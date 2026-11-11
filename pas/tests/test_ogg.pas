{ For each file given: split it into pages and gaps, write every page back
  and check that the pieces, in order, are exactly the original bytes.
  Prints the logical streams found. Exit code 1 if any file fails. }
program test_ogg;

{$I ../poa.inc}

uses SysUtils, Classes, poaogg;

function LoadFile(const fn: string): TBytes;
var
  f: TFileStream;
begin
  Result := nil;
  f := TFileStream.Create(fn, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, f.Size);
    if Length(Result) > 0 then f.ReadBuffer(Result[0], Length(Result));
  finally
    f.Free;
  end;
end;

function RoundTrip(const a: TBytes; const s: TOggScan): Boolean;
var
  i, p: SizeInt;
  b: TBytes;
  g: TOggGap;
begin
  p := 0;
  for i := 0 to High(s.Items) do
    if s.Items[i].IsPage then
    begin
      b := OggWritePage(s.Pages[s.Items[i].Index], a);
      if (Length(b) > Length(a) - p) or
         ((Length(b) > 0) and not CompareMem(@b[0], @a[p], Length(b))) then
        Exit(False);
      Inc(p, Length(b));
    end
    else
    begin
      g := s.Gaps[s.Items[i].Index];
      if g.Pos <> p then Exit(False);
      Inc(p, g.Len);
    end;
  Result := p = Length(a);
end;

var
  i, k, fails, gapBytes: SizeInt;
  a: TBytes;
  s: TOggScan;
  st: TOggStreams;
  line: string;
  ok: Boolean;
begin
  fails := 0;
  for i := 1 to ParamCount do
  begin
    a := LoadFile(ParamStr(i));
    OggScan(a, s);
    ok := RoundTrip(a, s);
    if not ok then Inc(fails);
    st := OggStreams(a, s);
    gapBytes := 0;
    for k := 0 to High(s.Gaps) do Inc(gapBytes, s.Gaps[k].Len);
    line := Format('%s %8d B  pages %5d  gaps %d (%d B) ',
      [BoolToStr(ok, 'ok  ', 'FAIL'), Length(a), Length(s.Pages), Length(s.Gaps), gapBytes]);
    for k := 0 to High(st) do
    begin
      line := line + Format(' [%s pk %d', [OggCodecName(st[k].Codec), st[k].Packets]);
      if st[k].BadCrc > 0 then line := line + Format(' badcrc %d', [st[k].BadCrc]);
      if st[k].Unterminated then line := line + ' open';
      line := line + ']';
    end;
    WriteLn(line, '  ', ExtractFileName(ParamStr(i)));
  end;
  WriteLn(ParamCount - fails, '/', ParamCount, ' round trips exact');
  if fails > 0 then Halt(1);
end.
