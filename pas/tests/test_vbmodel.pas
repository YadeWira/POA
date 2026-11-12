{ Compresses the Vorbis audio packets of each file with the model, then
  decompresses them with a fresh model and checks every packet comes back
  exact. Prints the size of the audio packets and of the coded stream. }
program test_vbmodel;

{$I ../poa.inc}

uses SysUtils, Classes, poaogg, poabits, poacm, poavorbis, poavbmodel;

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

{ bits used by the events (packet-type bit included) }
function EventBits(const s: TVorbisSetup; const p: TVbPacket): SizeInt;
var
  i: SizeInt;
begin
  Result := 1;
  for i := 0 to p.Count - 1 do
    with p.Events[i] do
      if IsCode then Inc(Result, s.Books[Book].Lengths[Val]) else Inc(Result, Book);
end;

function TailOf(const pk: TBytes; pos, n: SizeInt): TBytes;
var
  br: TBitReader;
  i: SizeInt;
begin
  Result := nil;
  SetLength(Result, (n + 7) div 8);
  if Length(Result) > 0 then FillChar(Result[0], Length(Result), 0);
  br.Init(pk, 0, Length(pk));
  br.Pos := pos;
  for i := 0 to n - 1 do
    if br.Bit <> 0 then Result[i shr 3] := Result[i shr 3] or (1 shl (i and 7));
end;

type
  TJob = record
    Setup: Integer;       { index into setups }
    Pk: TBytes;
  end;

var
  fi, k, i, j, nj: Integer;
  a, pk, outb, b, tail: TBytes;
  sc: TOggScan;
  st: TOggStreams;
  pks: TPacketList;
  setups: array of TVorbisSetup;
  jobs: array of TJob;
  vp, vq: TVbPacket;
  ac: TArith;
  m: TVbModel;
  src: TVbModelSource;
  bw: TBitWriter;
  audio, totA, totC: Int64;
  bad: Integer;
  t0: QWord;
  tg: TVbTag;
begin
  VbStats := GetEnvironmentVariable('VBSTATS') <> '';
  totA := 0; totC := 0;
  vp := Default(TVbPacket);
  vq := Default(TVbPacket);
  for fi := 1 to ParamCount do
  begin
    a := LoadFile(ParamStr(fi));
    OggScan(a, sc);
    st := OggStreams(a, sc);
    setups := nil;
    jobs := nil;
    nj := 0;
    for k := 0 to High(st) do
    begin
      if st[k].Codec <> ocVorbis then Continue;
      pks := OggStreamPackets(a, sc, st[k].Serial);
      for i := 0 to High(pks) do
      begin
        pk := pks[i];
        if (Length(pk) > 0) and ((pk[0] and 1) = 1) then
        begin
          if pk[0] = 1 then
          begin
            SetLength(setups, Length(setups) + 1);
            setups[High(setups)] := Default(TVorbisSetup);
            VorbisReadIdent(pk, 0, Length(pk), setups[High(setups)]);
          end
          else if (pk[0] = 5) and (Length(setups) > 0) then
            VorbisReadSetup(pk, 0, Length(pk), setups[High(setups)]);
          Continue;
        end;
        if (Length(setups) = 0) or not setups[High(setups)].HaveSetup then Continue;
        if VorbisReadAudio(setups[High(setups)], pk, 0, Length(pk), vp) <> vsOk then Continue;
        if nj >= Length(jobs) then SetLength(jobs, 2 * nj + 64);
        jobs[nj].Setup := High(setups);
        jobs[nj].Pk := pk;
        Inc(nj);
      end;
    end;
    if nj = 0 then Continue;

    { encode }
    t0 := GetTickCount64;
    audio := 0;
    ac.InitEncode;
    m := TVbModel.Create;
    for j := 0 to nj - 1 do
    begin
      pk := jobs[j].Pk;
      Inc(audio, Length(pk));
      VorbisReadAudio(setups[jobs[j].Setup], pk, 0, Length(pk), vp);
      m.SetSetup(setups[jobs[j].Setup]);
      m.StartPacket;
      for i := 0 to vp.Count - 1 do
        m.CodeEvent(ac, vp.Events[i]);
      tail := TailOf(pk, vp.TailPos, vp.TailBits);
      m.CodeTail(ac, tail, vp.TailBits);
    end;
    outb := ac.Finish;
    m.Free;
    Write(Format('%9d -> %9d  %6.2f%%  enc %5.2fs', [audio, Length(outb), 100.0 * Length(outb) / audio,
      (GetTickCount64 - t0) / 1000]));

    { decode }
    t0 := GetTickCount64;
    ac.InitDecode(outb, 0);
    m := TVbModel.Create;
    src := TVbModelSource.Create;
    src.Model := m;
    src.Ac := @ac;
    bad := 0;
    for j := 0 to nj - 1 do
    begin
      pk := jobs[j].Pk;
      m.SetSetup(setups[jobs[j].Setup]);
      m.StartPacket;
      if VorbisWalk(setups[jobs[j].Setup], src, vq) <> vsOk then begin Inc(bad); Break; end;
      i := Length(pk) * 8 - EventBits(setups[jobs[j].Setup], vq);
      if i < 0 then begin Inc(bad); Break; end;
      m.CodeTail(ac, tail, i);
      bw.Init;
      bw.Bit(0);
      for i := 0 to vq.Count - 1 do
        with vq.Events[i] do
          if IsCode then setups[jobs[j].Setup].Books[Book].Encode(bw, Val)
          else bw.Write(Val, Book);
      for i := 0 to Length(pk) * 8 - bw.Pos - 1 do
        bw.Bit((tail[i shr 3] shr (i and 7)) and 1);
      b := bw.Bytes;
      if (Length(b) <> Length(pk)) or not CompareMem(@b[0], @pk[0], Length(b)) then
      begin
        Inc(bad);
        Break;
      end;
    end;
    src.Free;
    m.Free;
    WriteLn(Format('  dec %5.2fs  %s  %s', [(GetTickCount64 - t0) / 1000,
      BoolToStr(bad = 0, 'ok', 'MISMATCH at ' + IntToStr(j)), ExtractFileName(ParamStr(fi))]));
    Inc(totA, audio);
    Inc(totC, Length(outb));
  end;
  WriteLn(Format('total %d -> %d  %.2f%%', [totA, totC, 100.0 * totC / totA]));
  if VbStats then
    for tg := Low(TVbTag) to High(TVbTag) do
      if VbCount[tg] > 0 then
        WriteLn(Format('  tag %2d: %9d events  %10.0f bytes  %.3f bits/event', [Ord(tg), VbCount[tg] div 2,
          VbCost[tg] / 16, VbCost[tg] / VbCount[tg]]));
end.
