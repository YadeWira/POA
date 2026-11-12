{ poa: the command line. First version: a, x, t and --version.

  a FILE [-o OUT]   compress FILE.ogg -> FILE.ogg.poa (decompressed and
                    compared before anything is written)
  x FILE.poa [-o OUT]
  t FILE.poa        decompress in memory and check size and BLAKE3

  Exit codes: 0 ok, 1 a file could not be processed, 2 usage, 3 bug. }
program poa;

{$I poa.inc}

uses
  {$ifdef unix}BaseUnix, Unix,{$endif}
  SysUtils, Classes, poaogg, poaformat, poaside;

const
  POA_VERSION = '0.0.1';

type
  EUsage = class(Exception);
  EFile = class(Exception);

function LoadFile(const fn: string): TBytes;
var
  f: TFileStream;
begin
  Result := nil;
  try
    f := TFileStream.Create(fn, fmOpenRead or fmShareDenyNone);
  except
    on e: Exception do raise EFile.CreateFmt('%s: cannot open (%s)', [fn, e.Message]);
  end;
  try
    SetLength(Result, f.Size);
    if Length(Result) > 0 then f.ReadBuffer(Result[0], Length(Result));
  finally
    f.Free;
  end;
end;

{ A temporary file next to the target, flushed to disk, then renamed to
  the target only if the target does not exist. }
procedure SaveDurable(const fn: string; const b: TBytes);
var
  tmp, dir: string;
  f: TFileStream;
  {$ifdef unix}fd: cint;{$endif}
begin
  if FileExists(fn) then raise EFile.CreateFmt('%s: already exists, not overwritten', [fn]);
  tmp := fn + '.poa-tmp' + IntToStr(GetProcessID);
  f := TFileStream.Create(tmp, fmCreate);
  try
    try
      if Length(b) > 0 then f.WriteBuffer(b[0], Length(b));
      {$ifdef unix}
      if fpfsync(f.Handle) <> 0 then raise EFile.CreateFmt('%s: fsync failed', [tmp]);
      {$endif}
    finally
      f.Free;
    end;
    if FileExists(fn) then raise EFile.CreateFmt('%s: already exists, not overwritten', [fn]);
    if not RenameFile(tmp, fn) then raise EFile.CreateFmt('%s: cannot rename the temporary file', [fn]);
  except
    DeleteFile(tmp);
    raise;
  end;
  {$ifdef unix}
  dir := ExtractFileDir(ExpandFileName(fn));
  fd := fpopen(dir, O_RDONLY);
  if fd >= 0 then
  begin
    fpfsync(fd);
    fpclose(fd);
  end;
  {$endif}
end;

function Max(a, b: SizeInt): SizeInt;
begin
  if a > b then Result := a else Result := b;
end;

procedure CmdCompress(const inFn: string; outFn: string);
var
  a, c, back: TBytes;
  st: TPoaStats;
  sc: TOggScan;
  t0: QWord;
begin
  if outFn = '' then outFn := inFn + '.poa';
  a := LoadFile(inFn);
  OggScan(a, sc);
  if Length(sc.Pages) = 0 then raise EFile.CreateFmt('%s: not an Ogg file (no Ogg page found)', [inFn]);
  t0 := GetTickCount64;
  c := PoaEncode(a, st);
  back := PoaDecode(c);
  if (Length(back) <> Length(a)) or ((Length(a) > 0) and not CompareMem(@back[0], @a[0], Length(a))) then
    raise Exception.CreateFmt('%s: decompressing gives other bytes; nothing written', [inFn]);
  SaveDurable(outFn, c);
  WriteLn(Format('%s: %d -> %d (%.2f%%)  %d streams, %d pages, %d Vorbis packets modelled, %d raw  %.2f s',
    [inFn, Length(a), Length(c), 100.0 * Length(c) / Max(1, Length(a)), st.Streams, st.Pages,
     st.VorbisEvents, st.VorbisRaw + st.OtherPackets, (GetTickCount64 - t0) / 1000]));
end;


procedure CmdExtract(const inFn: string; outFn: string; testOnly: Boolean);
var
  c, a: TBytes;
begin
  c := LoadFile(inFn);
  if not PoaIsPoa(c) then raise EFile.CreateFmt('%s: not a .poa file', [inFn]);
  try
    a := PoaDecode(c);
  except
    on e: EPoaFormat do raise EFile.CreateFmt('%s: %s', [inFn, e.Message]);
  end;
  if testOnly then
  begin
    WriteLn(Format('%s: ok (%d bytes, BLAKE3 matches)', [inFn, Length(a)]));
    Exit;
  end;
  if outFn = '' then
  begin
    if LowerCase(ExtractFileExt(inFn)) = '.poa' then
      outFn := ChangeFileExt(inFn, '')
    else
      outFn := inFn + '.out';
  end;
  SaveDurable(outFn, a);
  WriteLn(Format('%s -> %s (%d bytes)', [inFn, outFn, Length(a)]));
end;

procedure Usage;
begin
  WriteLn('poa ', POA_VERSION, ': lossless recompression of Ogg files');
  WriteLn('usage: poa a FILE [-o OUT]    compress');
  WriteLn('       poa x FILE.poa [-o OUT] extract');
  WriteLn('       poa t FILE.poa         test');
  WriteLn('       poa --version');
end;

var
  cmd, outFn: string;
  files: TStringList;
  i, rc: Integer;
begin
  rc := 0;
  poaside.Trace := GetEnvironmentVariable('POA_TRACE') <> '';
  files := TStringList.Create;
  try
    try
      if ParamCount = 0 then begin Usage; Halt(2); end;
      cmd := ParamStr(1);
      if (cmd = '--version') or (cmd = '-V') then
      begin
        WriteLn('poa ', POA_VERSION, ' (format ', POA_FORMAT, ')');
        Halt(0);
      end;
      if (cmd = '-h') or (cmd = '--help') then begin Usage; Halt(0); end;
      outFn := '';
      i := 2;
      while i <= ParamCount do
      begin
        if ParamStr(i) = '-o' then
        begin
          if i = ParamCount then raise EUsage.Create('-o needs a file name');
          outFn := ParamStr(i + 1);
          Inc(i, 2);
          Continue;
        end;
        files.Add(ParamStr(i));
        Inc(i);
      end;
      if files.Count = 0 then raise EUsage.Create('no input file');
      if (outFn <> '') and (files.Count > 1) then raise EUsage.Create('-o takes a single input');
      for i := 0 to files.Count - 1 do
        try
          if cmd = 'a' then CmdCompress(files[i], outFn)
          else if cmd = 'x' then CmdExtract(files[i], outFn, False)
          else if cmd = 't' then CmdExtract(files[i], '', True)
          else raise EUsage.CreateFmt('unknown command "%s"', [cmd]);
        except
          on e: EFile do
          begin
            WriteLn(StdErr, 'poa: ', e.Message);
            rc := 1;
          end;
        end;
    except
      on e: EUsage do
      begin
        WriteLn(StdErr, 'poa: ', e.Message);
        Usage;
        rc := 2;
      end;
      on e: Exception do
      begin
        WriteLn(StdErr, 'poa: ', e.ClassName, ': ', e.Message);
        WriteLn(StdErr, 'This is a bug in poa. Please report it with the file that caused it.');
        rc := 3;
      end;
    end;
  finally
    files.Free;
  end;
  Halt(rc);
end.
