{ For each Vorbis stream in the files given: read the headers, turn every
  audio packet into events and write it back. Reports how many packets
  became events, how many stayed as bytes (and why), and how many came
  back different (that last number must be 0). }
program test_vorbis;

{$I ../poa.inc}

uses SysUtils, Classes, poaogg, poabits, poavorbis;

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

var
  fi, k, i: Integer;
  a, b, pk: TBytes;
  sc: TOggScan;
  st: TOggStreams;
  pks: TPacketList;
  vs: TVorbisSetup;
  vp: TVbPacket;
  stt: TVbStatus;
  nOk, nRaw, nBad, nEv, tailBits, totBits, totOk, totRaw, totBad: Int64;
  why: array[TVbStatus] of Int64;
  w: TVbStatus;
  line: string;
begin
  totOk := 0; totRaw := 0; totBad := 0;
  vp := Default(TVbPacket);
  for fi := 1 to ParamCount do
  begin
    a := LoadFile(ParamStr(fi));
    OggScan(a, sc);
    st := OggStreams(a, sc);
    for k := 0 to High(st) do
    begin
      if st[k].Codec <> ocVorbis then Continue;
      pks := OggStreamPackets(a, sc, st[k].Serial);
      vs := Default(TVorbisSetup);
      nOk := 0; nRaw := 0; nBad := 0; nEv := 0; tailBits := 0; totBits := 0;
      FillChar(why, SizeOf(why), 0);
      for i := 0 to High(pks) do
      begin
        pk := pks[i];
        if (Length(pk) > 0) and ((pk[0] and 1) = 1) then
        begin
          case pk[0] of
            1: VorbisReadIdent(pk, 0, Length(pk), vs);
            5: if not VorbisReadSetup(pk, 0, Length(pk), vs) then
                 WriteLn('  setup header not read');
          end;
          Continue;
        end;
        stt := VorbisReadAudio(vs, pk, 0, Length(pk), vp);
        Inc(totBits, Length(pk) * 8);
        if stt <> vsOk then
        begin
          Inc(nRaw);
          Inc(why[stt]);
          Continue;
        end;
        b := VorbisReencode(vs, vp, pk, 0, Length(pk));
        if (Length(b) <> Length(pk)) or ((Length(b) > 0) and not CompareMem(@b[0], @pk[0], Length(b))) then
          Inc(nBad)
        else
          Inc(nOk);
        Inc(nEv, vp.Count);
        Inc(tailBits, vp.TailBits);
      end;
      line := Format('%-6s ok %6d raw %4d BAD %d  events %8d  tail %.2f%%',
        [IntToStr(vs.Channels) + 'ch', nOk, nRaw, nBad, nEv, 100.0 * tailBits / (totBits + 1)]);
      for w := Low(w) to High(w) do
        if why[w] > 0 then line := line + Format(' %d:%d', [Ord(w), why[w]]);
      WriteLn(line, '  ', ExtractFileName(ParamStr(fi)));
      Inc(totOk, nOk); Inc(totRaw, nRaw); Inc(totBad, nBad);
    end;
  end;
  WriteLn(Format('total: %d as events, %d as bytes, %d different', [totOk, totRaw, totBad]));
  if totBad > 0 then Halt(1);
end.
