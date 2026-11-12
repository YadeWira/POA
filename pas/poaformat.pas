{ The .poa format: a whole Ogg file in one arithmetic-coded stream.

  File layout:
    "POA" 1A | format (1 byte) | flags (1 byte) | original size (8 bytes LE)
    | BLAKE3-128 of the original (16 bytes) | coded stream

  Flags: bit 0 = stored (the coded stream would not be smaller, so the
  original bytes follow as they are). Other bits are 0.

  The coded stream, in order:
    1. the logical streams: count, then for each its serial, packet count
       and whether its last packet is left open (a cut stream);
    2. every stream's packets, stream after stream. Vorbis audio packets go
       through the Vorbis model (poavbmodel); everything else is coded as
       bytes, with its length;
    3. the file's items in order: gaps (bytes between pages) and pages.
       A page is rebuilt from the packets: only its stream, segment count,
       flags, granule position, sequence number and CRC state are coded,
       each against a prediction.

  Lacing is never stored: a page's lacing follows from the lengths of the
  packets it carries and its segment count. }
unit poaformat;

{$I poa.inc}
{$ifopt R-}{$fatal poaformat: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poaformat: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, poaogg, poabits, poacm, poaside, poavorbis, poavbmodel, poablake3;

const
  POA_FORMAT = 1;
  POA_HEADER = 4 + 1 + 1 + 8 + 16;

type
  EPoaFormat = poaside.EPoaFormat;

  TPoaStats = record
    Streams, Pages, Gaps: SizeInt;
    VorbisEvents, VorbisRaw, OtherPackets: SizeInt;
  end;

{ The .poa bytes for a file. Does not verify: the caller decodes and
  compares before writing anything. }
function PoaEncode(const a: TBytes; out st: TPoaStats): TBytes;

{ The original file. Raises EPoaFormat on a damaged or foreign input;
  checks the size and the BLAKE3 stored in the header. }
function PoaDecode(const c: TBytes): TBytes;

function PoaIsPoa(const c: TBytes): Boolean;

implementation

const
  MAGIC: array[0..3] of Byte = (Ord('P'), Ord('O'), Ord('A'), $1A);
  FLAG_STORED = 1;

type
  TPacket = TBytes;

  TStreamInfo = record
    Serial: LongWord;
    Codec: TOggCodec;
    Pk: array of TPacket;
    NPk: SizeInt;
    Open: Boolean;
    Dur: array of Int64;        { samples each packet adds (Vorbis), 0 if unknown }
  end;

  { Per-stream state shared by encoder and decoder. }
  TCodecState = record
    Vs: TVorbisSetup;
    PrevBlock: Integer;         { block size of the previous audio packet, 0 = none }
  end;

  TCoder = class
    Ac: TArith;
    Side: TSideModels;
    Vm: TVbModel;
    VmSrc: TVbModelSource;
    Streams: array of TStreamInfo;
    States: array of TCodecState;
    Stats: TPoaStats;
    TabBits: Integer;
    constructor Create(size: QWord);
    destructor Destroy; override;
    procedure CodeStreams;
    procedure CodePacket(k: Integer; var pk: TPacket; idx: SizeInt);
    procedure NoteVorbisPacket(k: Integer; const pk: TPacket; idx: SizeInt);
  end;

{ ---- the coder ---- }

constructor TCoder.Create(size: QWord);
begin
  inherited Create;
  TabBits := TableBits(size);
  Side := TSideModels.Create(TabBits);
  Vm := nil;
  VmSrc := nil;
end;

destructor TCoder.Destroy;
begin
  Side.Free;
  Vm.Free;
  VmSrc.Free;
  inherited Destroy;
end;

{ Header packets update the setup; audio packets give their duration. }
procedure TCoder.NoteVorbisPacket(k: Integer; const pk: TPacket; idx: SizeInt);
var
  br: TBitReader;
  mode, bs: Integer;
begin
  with States[k] do
  begin
    Streams[k].Dur[idx] := 0;
    if Length(pk) = 0 then Exit;
    if (pk[0] and 1) = 1 then
    begin
      case pk[0] of
        1: begin
             Vs := Default(TVorbisSetup);
             VorbisReadIdent(pk, 0, Length(pk), Vs);
             PrevBlock := 0;
           end;
        5: VorbisReadSetup(pk, 0, Length(pk), Vs);
      end;
      Exit;
    end;
    if not Vs.HaveSetup then Exit;
    br.Init(pk, 0, Length(pk));
    br.Read(1);
    mode := br.Read(Vs.ModeBits);
    if br.Eop or (mode >= Length(Vs.Modes)) then Exit;
    if Vs.Modes[mode].BlockFlag <> 0 then bs := Vs.Block1 else bs := Vs.Block0;
    if PrevBlock > 0 then
      Streams[k].Dur[idx] := PrevBlock div 4 + bs div 4;
    PrevBlock := bs;
  end;
end;

function EventBits(const s: TVorbisSetup; const p: TVbPacket): SizeInt;
var
  i: SizeInt;
begin
  Result := 1;
  for i := 0 to p.Count - 1 do
    with p.Events[i] do
      if IsCode then Inc(Result, s.Books[Book].Lengths[Val]) else Inc(Result, Book);
end;

const
  KIND_RAW = 0;
  KIND_VORBIS = 1;

procedure TCoder.CodePacket(k: Integer; var pk: TPacket; idx: SizeInt);
var
  kind, salt: Integer;
  vp: TVbPacket;
  i, n, tailBits: SizeInt;
  tail: TBytes;
  br: TBitReader;
  bw: TBitWriter;
  s: ^TVorbisSetup;
begin
  s := @States[k].Vs;
  kind := KIND_RAW;
  vp := Default(TVbPacket);
  if (Streams[k].Codec = ocVorbis) and s^.HaveSetup then
  begin
    if Ac.Encoding then
      if (Length(pk) > 0) and ((pk[0] and 1) = 0) and
         (VorbisReadAudio(s^, pk, 0, Length(pk), vp) = vsOk) then
        kind := KIND_VORBIS;
    kind := Side.CodeFlag(Ac, kind, 1);
  end;

  if kind = KIND_VORBIS then
  begin
    if Vm = nil then
    begin
      Vm := TVbModel.Create(TabBits);
      VmSrc := TVbModelSource.Create;
      VmSrc.Model := Vm;
      VmSrc.Ac := @Ac;
    end;
    Vm.SetSetup(s^);
    Vm.StartPacket;
    if Ac.Encoding then
    begin
      for i := 0 to vp.Count - 1 do
        Vm.CodeEvent(Ac, vp.Events[i]);
      tailBits := vp.TailBits;
    end
    else
    begin
      if VorbisWalk(s^, VmSrc, vp) <> vsOk then
        raise EPoaFormat.Create('damaged stream (Vorbis packet)');
      tailBits := 0;
    end;
    tailBits := Side.CodeNum(Ac, tailBits, 2);
    if Ac.Encoding then
    begin
      tail := nil;
      SetLength(tail, (tailBits + 7) div 8);
      if Length(tail) > 0 then FillChar(tail[0], Length(tail), 0);
      br.Init(pk, 0, Length(pk));
      br.Pos := vp.TailPos;
      for i := 0 to tailBits - 1 do
        if br.Bit <> 0 then tail[i shr 3] := tail[i shr 3] or (1 shl (i and 7));
    end;
    Vm.CodeTail(Ac, tail, tailBits);
    if not Ac.Encoding then
    begin
      n := EventBits(s^, vp) + tailBits;
      if (n and 7) <> 0 then raise EPoaFormat.Create('damaged stream (Vorbis length)');
      bw.Init;
      bw.Bit(0);
      for i := 0 to vp.Count - 1 do
        with vp.Events[i] do
          if IsCode then s^.Books[Book].Encode(bw, Val) else bw.Write(Val, Book);
      for i := 0 to tailBits - 1 do
        bw.Bit((tail[i shr 3] shr (i and 7)) and 1);
      pk := bw.Bytes;
    end;
    Inc(Stats.VorbisEvents);
  end
  else
  begin
    n := Side.CodeNum(Ac, Length(pk), 3 + Ord(Streams[k].Codec) * 4);
    if not Ac.Encoding and (n > 1 shl 30) then raise EPoaFormat.Create('damaged stream (length)');
    if idx < 3 then salt := idx else salt := 3;
    salt := 1000 + Ord(Streams[k].Codec) * 8 + salt;
    Side.CodeBytes(Ac, pk, n, salt);
    if Streams[k].Codec = ocVorbis then Inc(Stats.VorbisRaw) else Inc(Stats.OtherPackets);
  end;
  if Streams[k].Codec = ocVorbis then
    NoteVorbisPacket(k, pk, idx);
end;

procedure TCoder.CodeStreams;
var
  k, i: SizeInt;
  pk: TPacket;
  total: SizeInt;
  cv: QWord;
begin
  total := Side.CodeNum(Ac, Length(Streams), 4);
  if not Ac.Encoding then
  begin
    if total > 1 shl 20 then raise EPoaFormat.Create('damaged stream (streams)');
    SetLength(Streams, total);
  end;
  SetLength(States, Length(Streams));
  for k := 0 to High(Streams) do
    with Streams[k] do
    begin
      Serial := Side.CodeNum(Ac, Serial, 5);
      cv := Side.CodeNum(Ac, Ord(Codec), 6);
      if cv > Ord(High(TOggCodec)) then raise EPoaFormat.Create('damaged stream (codec)');
      Codec := TOggCodec(cv);
      NPk := Side.CodeNum(Ac, NPk, 7);
      if not Ac.Encoding then
      begin
        if NPk > 1 shl 28 then raise EPoaFormat.Create('damaged stream (packets)');
        SetLength(Pk, NPk);
      end;
      Open := Side.CodeFlag(Ac, Ord(Open), 8) <> 0;
      SetLength(Dur, NPk);
      States[k] := Default(TCodecState);
    end;
  for k := 0 to High(Streams) do
  begin
    for i := 0 to Streams[k].NPk - 1 do
    begin
      pk := Streams[k].Pk[i];
      CodePacket(k, pk, i);
      Streams[k].Pk[i] := pk;
    end;
  end;
end;

{ ---- splitting a file into streams ---- }

type
  TStreamArray = array of TStreamInfo;

function Split(const a: TBytes; const sc: TOggScan; out pageStream: TIntArray): TStreamArray;
var
  i, j, k, seg, pos, n: SizeInt;
  cur: array of TBytes;
  open: array of Boolean;
begin
  Result := nil;
  cur := nil;
  open := nil;
  pageStream := nil;
  SetLength(pageStream, Length(sc.Pages));
  for i := 0 to High(sc.Pages) do
    with sc.Pages[i] do
    begin
      k := -1;
      for j := High(Result) downto 0 do
        if Result[j].Serial = Serial then begin k := j; Break; end;
      if (k < 0) or ((HType and OGG_FLAG_BOS) <> 0) then
      begin
        k := Length(Result);
        SetLength(Result, k + 1);
        SetLength(cur, k + 1);
        SetLength(open, k + 1);
        Result[k] := Default(TStreamInfo);
        Result[k].Serial := Serial;
        cur[k] := nil;
        open[k] := False;
      end;
      pageStream[i] := k;
      pos := DataPos;
      for seg := 0 to NSeg - 1 do
      begin
        if Lacing[seg] > 0 then
        begin
          j := Length(cur[k]);
          SetLength(cur[k], j + Lacing[seg]);
          Move(a[pos], cur[k][j], Lacing[seg]);
          Inc(pos, Lacing[seg]);
        end;
        if Lacing[seg] < 255 then
        begin
          n := Result[k].NPk;
          if n >= Length(Result[k].Pk) then SetLength(Result[k].Pk, 2 * n + 16);
          Result[k].Pk[n] := cur[k];
          Inc(Result[k].NPk);
          cur[k] := nil;
          open[k] := False;
        end
        else
          open[k] := True;
      end;
    end;
  for k := 0 to High(Result) do
  begin
    if open[k] then
    begin
      n := Result[k].NPk;
      SetLength(Result[k].Pk, n + 1);
      Result[k].Pk[n] := cur[k];
      Inc(Result[k].NPk);
      Result[k].Open := True;
    end;
    SetLength(Result[k].Pk, Result[k].NPk);
    if Result[k].NPk > 0 then
      Result[k].Codec := OggIdentify(Result[k].Pk[0]);
  end;
end;

{ ---- pages ---- }

type
  TCursor = record
    Pk: SizeInt;                { current packet }
    Off: SizeInt;               { bytes of it already in pages }
    Seq: LongWord;
    Pages: SizeInt;
    LastGran: QWord;
    LastDelta: QWord;
  end;

const
  GRAN_NONE = QWord($FFFFFFFFFFFFFFFF);

{$push}{$Q-}{$R-}
function WrapSub(a, b: QWord): QWord; begin Result := a - b; end;
function WrapAdd(a, b: QWord): QWord; begin Result := a + b; end;
function ZigZag(d: QWord): QWord; begin Result := (d shl 1) xor QWord(-Int64(d shr 63)); end;
function UnZigZag(z: QWord): QWord; begin Result := (z shr 1) xor QWord(-Int64(z and 1)); end;
{$pop}

{ Lacing of the next page with nseg segments, from the stream's packets;
  advances the cursor. Returns the data length and how many packets end
  on the page; False if the packets run out. }
function NextLacing(const s: TStreamInfo; var c: TCursor; nseg: Integer;
  var lac: array of Byte; var data: TBytes; out dataLen: SizeInt; out ended: SizeInt;
  out durSum: Int64): Boolean;
var
  i: Integer;
  rem, n: SizeInt;
begin
  dataLen := 0;
  ended := 0;
  durSum := 0;
  for i := 0 to nseg - 1 do
  begin
    if c.Pk >= s.NPk then Exit(False);
    rem := Length(s.Pk[c.Pk]) - c.Off;
    if rem >= 255 then n := 255 else n := rem;
    if dataLen + n > Length(data) then SetLength(data, 2 * Length(data) + 256 * 255);
    if n > 0 then Move(s.Pk[c.Pk][c.Off], data[dataLen], n);
    Inc(dataLen, n);
    if rem >= 255 then
    begin
      lac[i] := 255;
      Inc(c.Off, 255);
    end
    else
    begin
      lac[i] := rem;
      Inc(durSum, s.Dur[c.Pk]);
      Inc(ended);
      Inc(c.Pk);
      c.Off := 0;
    end;
  end;
  Result := True;
end;

procedure CodePages(cd: TCoder; const a: TBytes; const sc: TOggScan; const pageStream: TIntArray;
  var outb: TBytes; var outLen: SizeInt);
var
  nItems, it, k, prevK, prevKind, nseg, i, j: SizeInt;
  cur: array of TCursor;
  pg: TOggPage;
  isPage: Integer;
  gap: TBytes;
  gran, pred: QWord;
  predH, v: LongWord;
  ended: SizeInt;
  dur: Int64;
  dataLen: SizeInt;
  lac: array[0..254] of Byte;
  enc: Boolean;
  page, data: TBytes;

  procedure Emit(const b: TBytes; first, n: SizeInt);
  begin
    if n = 0 then Exit;
    while outLen + n > Length(outb) do SetLength(outb, 2 * Length(outb) + n);
    Move(b[first], outb[outLen], n);
    Inc(outLen, n);
  end;

begin
  enc := cd.Ac.Encoding;
  data := nil;
  with cd do
  begin
    SetLength(cur, Length(Streams));
    for k := 0 to High(cur) do
    begin
      cur[k] := Default(TCursor);
      cur[k].LastGran := 0;
    end;
    nItems := Side.CodeNum(Ac, Length(sc.Items), 20);
    if not enc and (nItems > 1 shl 30) then raise EPoaFormat.Create('damaged stream (items)');
    prevK := 0;
    prevKind := 1;
    for it := 0 to nItems - 1 do
    begin
      if enc then isPage := Ord(sc.Items[it].IsPage) else isPage := 0;
      isPage := Side.CodeFlag(Ac, isPage, 30 + prevKind);
      prevKind := isPage;
      if isPage = 0 then
      begin
        gap := nil;
        if enc then
        begin
          with sc.Gaps[sc.Items[it].Index] do
            gap := Copy(a, Pos, Len);
        end;
        i := Side.CodeNum(Ac, Length(gap), 21);
        Side.CodeBytes(Ac, gap, i, 900);
        Emit(gap, 0, Length(gap));
        Inc(Stats.Gaps);
        Continue;
      end;
      Inc(Stats.Pages);
      if enc then
      begin
        pg := sc.Pages[sc.Items[it].Index];
        k := pageStream[sc.Items[it].Index];
      end
      else
      begin
        pg := Default(TOggPage);
        k := 0;
      end;
      k := Side.CodeNum(Ac, LongWord(k xor prevK), 22) xor QWord(prevK);
      if k >= Length(Streams) then raise EPoaFormat.Create('damaged stream (page stream)');
      prevK := k;
      { segment count }
      nseg := Side.CodeNum(Ac, pg.NSeg, 23 + 8 * Ord(Streams[k].Codec));
      if nseg > 255 then raise EPoaFormat.Create('damaged stream (segments)');
      pg.NSeg := nseg;
      { flags }
      predH := 0;
      if cur[k].Off > 0 then predH := predH or OGG_FLAG_CONT;
      if cur[k].Pages = 0 then predH := predH or OGG_FLAG_BOS;
      v := Side.CodeNum(Ac, pg.HType xor predH, 24);
      if v > 255 then raise EPoaFormat.Create('damaged stream (flags)');
      pg.HType := v xor predH;
      { lacing from the packets }
      if not NextLacing(Streams[k], cur[k], nseg, lac, data, dataLen, ended, dur) then
        raise EPoaFormat.Create('damaged stream (lacing)');
      if enc then
        for j := 0 to nseg - 1 do
          if lac[j] <> pg.Lacing[j] then raise EPoaFormat.Create('internal: lacing mismatch');
      for j := 0 to nseg - 1 do pg.Lacing[j] := lac[j];
      { granule }
      if ended = 0 then
        pred := GRAN_NONE
      else if Streams[k].Codec = ocVorbis then
        pred := WrapAdd(cur[k].LastGran, QWord(dur))
      else
        pred := WrapAdd(cur[k].LastGran, cur[k].LastDelta);
      if enc then gran := pg.Granule else gran := 0;
      i := Side.CodeFlag(Ac, Ord(gran = pred), 40 + Ord(ended = 0) + 2 * Ord(Streams[k].Codec));
      if i <> 0 then
        gran := pred
      else
        gran := WrapAdd(pred, UnZigZag(Side.CodeNum(Ac, ZigZag(WrapSub(gran, pred)), 25)));
      pg.Granule := gran;
      if gran <> GRAN_NONE then
      begin
        cur[k].LastDelta := WrapSub(gran, cur[k].LastGran);
        cur[k].LastGran := gran;
      end;
      { sequence number }
      if cur[k].Pages = 0 then v := 0 else v := cur[k].Seq + 1;
      if enc then i := Ord(pg.SeqNo = v) else i := 0;
      i := Side.CodeFlag(Ac, i, 70);
      if i <> 0 then
        pg.SeqNo := v
      else
        pg.SeqNo := Side.CodeNum(Ac, pg.SeqNo, 26);
      cur[k].Seq := pg.SeqNo;
      Inc(cur[k].Pages);
      pg.Serial := Streams[k].Serial;
      { CRC }
      i := Side.CodeFlag(Ac, Ord(pg.CrcOk), 71);
      pg.CrcOk := i <> 0;
      if not pg.CrcOk then
        pg.Crc := Side.CodeNum(Ac, pg.Crc, 27);
      { the page itself (decoding) }
      if not enc then
      begin
        pg.DataPos := 0;
        pg.DataLen := dataLen;
        page := OggWritePage(pg, data);
        Emit(page, 0, Length(page));
      end;
    end;
  end;
end;

{ ---- top level ---- }

procedure Wr64(var b: TBytes; p: SizeInt; v: QWord);
var
  i: Integer;
begin
  for i := 0 to 7 do b[p + i] := (v shr (8 * i)) and $FF;
end;

function Rd64(const b: TBytes; p: SizeInt): QWord;
var
  i: Integer;
begin
  Result := 0;
  for i := 7 downto 0 do Result := (Result shl 8) or b[p + i];
end;

function PoaIsPoa(const c: TBytes): Boolean;
begin
  Result := (Length(c) >= POA_HEADER) and (c[0] = MAGIC[0]) and (c[1] = MAGIC[1]) and
            (c[2] = MAGIC[2]) and (c[3] = MAGIC[3]);
end;

function PoaEncode(const a: TBytes; out st: TPoaStats): TBytes;
var
  cd: TCoder;
  sc: TOggScan;
  ps: TIntArray;
  body, dummy: TBytes;
  dl: SizeInt;
  h: THash16;
begin
  OggScan(a, sc);
  cd := TCoder.Create(Length(a));
  try
    cd.Streams := Split(a, sc, ps);
    cd.Ac.InitEncode;
    cd.CodeStreams;
    dummy := nil;
    dl := 0;
    CodePages(cd, a, sc, ps, dummy, dl);
    body := cd.Ac.Finish;
    st := cd.Stats;
    st.Streams := Length(cd.Streams);
  finally
    cd.Free;
  end;
  Result := nil;
  SetLength(Result, POA_HEADER + Length(body));
  FillChar(Result[0], POA_HEADER, 0);
  Move(MAGIC[0], Result[0], 4);
  Result[4] := POA_FORMAT;
  Result[5] := 0;
  if Length(body) >= Length(a) then
  begin
    body := a;
    SetLength(Result, POA_HEADER + Length(body));
    Result[5] := FLAG_STORED;
  end;
  Wr64(Result, 6, Length(a));
  h := Blake3_128(a);
  Move(h[0], Result[14], 16);
  if Length(body) > 0 then Move(body[0], Result[POA_HEADER], Length(body));
end;

function PoaDecode(const c: TBytes): TBytes;
var
  cd: TCoder;
  sc: TOggScan;
  ps: TIntArray;
  size: QWord;
  outLen: SizeInt;
  h: THash16;
  i: Integer;
begin
  if not PoaIsPoa(c) then raise EPoaFormat.Create('not a .poa file');
  if c[4] <> POA_FORMAT then
    raise EPoaFormat.CreateFmt('.poa format %d is not known to this version', [c[4]]);
  if (c[5] and not FLAG_STORED) <> 0 then raise EPoaFormat.Create('damaged header (flags)');
  size := Rd64(c, 6);
  if size > QWord(High(SizeInt)) then raise EPoaFormat.Create('damaged header (size)');
  Result := nil;
  if (c[5] and FLAG_STORED) <> 0 then
  begin
    if QWord(Length(c) - POA_HEADER) <> size then raise EPoaFormat.Create('damaged: size differs');
    Result := Copy(c, POA_HEADER, size);
    h := Blake3_128(Result);
    for i := 0 to 15 do
      if h[i] <> c[14 + i] then raise EPoaFormat.Create('damaged: BLAKE3 differs');
    Exit;
  end;
  SetLength(Result, size);
  outLen := 0;
  sc.Clear;
  ps := nil;
  cd := TCoder.Create(size);
  try
    cd.Ac.InitDecode(c, POA_HEADER);
    cd.CodeStreams;
    CodePages(cd, nil, sc, ps, Result, outLen);
  finally
    cd.Free;
  end;
  if QWord(outLen) <> size then raise EPoaFormat.Create('damaged: size differs');
  SetLength(Result, outLen);
  h := Blake3_128(Result);
  for i := 0 to 15 do
    if h[i] <> c[14 + i] then raise EPoaFormat.Create('damaged: BLAKE3 differs');
end;

end.
