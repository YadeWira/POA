{ Vorbis I (xiph.org/vorbis/doc/Vorbis_I_spec.html): the three header
  packets, and the audio packets read down to the symbols they carry
  (mode, window flags, floor values, residue classifications and VQ
  entries) without decoding any audio.

  An audio packet becomes a list of events: raw fields and codebook
  entries, each tagged with the syntax element it belongs to. Whatever
  follows the last symbol (the padding up to the end of the packet) is
  the tail and is kept as bits. Writing the events and the tail back
  gives the packet's bytes; VorbisReencode does it and the caller
  compares. A packet that cannot be read to its end (a codeword that is
  not in its codebook, the end of the packet in the middle of a symbol)
  is not turned into events: it stays as bytes. }
unit poavorbis;

{$I poa.inc}
{$ifopt R-}{$fatal poavorbis: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poavorbis: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, poabits;

const
  VB_MAX_CH = 255;

type
  TIntArray = array of Integer;

  { A codebook. Codewords are canonical: they follow from the lengths in
    entry order, as the specification assigns them. Decoding walks a
    binary tree built from them. }
  TVorbisBook = record
    Dims, Entries: Integer;
    Lengths: array of Byte;       { 0 = unused entry }
    Codes: array of LongWord;     { MSB first, Lengths[i] bits }
    Used: Integer;
    Tree: array of array[0..1] of Integer;   { >= 0 node, < 0: -(entry+1); 0 at a leaf slot = none }
    LookupType: Integer;
    LookupValues: Integer;        { type 1: values per dimension (the radix) }
    MinV, DeltaV: LongWord;       { packed float32 of the specification }
    SeqP: Boolean;
    Mult: array of Integer;       { multiplicands }
    Grid: Boolean;                { type 1 and Entries = LookupValues^Dims: an entry is its digits }
    ValQ: array of Integer;       { type 1: value of each digit, in 1/16 (deterministic, clamped) }
    function Decode(var br: TBitReader): Integer;   { -1: invalid codeword or end of packet }
    procedure Encode(var bw: TBitWriter; e: Integer);
  end;

  TFloor0 = record
    Order, Rate, BarkMapSize, AmpBits, AmpOffset: Integer;
    Books: TIntArray;
  end;

  TFloor1 = record
    Partitions: Integer;
    PartClass: TIntArray;
    ClassDim, ClassSub, ClassMaster: TIntArray;
    SubBooks: array of TIntArray;   { [class][1 shl sub], -1 = none }
    Multiplier, RangeBits: Integer;
    X: TIntArray;                   { all X values, with the two implicit ones first }
    LowN, HighN: TIntArray;         { low_neighbor and high_neighbor of each X (from 2 on) }
    Sorted: TIntArray;              { post indices in increasing X }
    Range: Integer;                 { 256, 128, 86 or 64 }
  end;

  TFloor = record
    FType: Integer;
    F0: TFloor0;
    F1: TFloor1;
  end;

  TResidue = record
    RType: Integer;
    RBegin, REnd, PartSize, Classes, ClassBook: Integer;
    Books: array of array[0..7] of Integer;   { -1 = none }
  end;

  TMapping = record
    Submaps: Integer;
    CouplingSteps: Integer;
    Magnitude, Angle: TIntArray;
    Mux: TIntArray;                 { per channel }
    SubFloor, SubResidue: TIntArray;
  end;

  TMode = record
    BlockFlag: Integer;
    Mapping: Integer;
  end;

  TVorbisSetup = record
    Channels: Integer;
    Rate: LongWord;
    Block0, Block1: Integer;
    Books: array of TVorbisBook;
    Floors: array of TFloor;
    Residues: array of TResidue;
    Mappings: array of TMapping;
    Modes: array of TMode;
    ModeBits: Integer;
    HaveIdent, HaveSetup: Boolean;
  end;

  { The syntax element an event belongs to. }
  TVbTag = (vtMode, vtWinPrev, vtWinNext, vtFloorNZ, vtFloorY0, vtFloorY1,
            vtFloorMaster, vtFloorY, vtF0Amp, vtF0Book, vtF0Vec,
            vtResClass, vtResVec);

  TVbEvent = record
    Tag: TVbTag;
    IsCode: Boolean;              { codebook entry, else raw field }
    Ch: Byte;                     { channel (for residue type 2: the submap's first) }
    Pass: Byte;                   { residue pass; floor: partition class index }
    Book: SmallInt;               { codebook, or the field's width in bits }
    Pos: Word;                    { residue: partition; floor: index of the Y value }
    Sub: Word;                    { residue vector: codeword within the partition }
    Val: LongWord;
  end;

  TVbPacket = record
    Events: array of TVbEvent;
    Count: SizeInt;
    TailPos, TailBits: SizeInt;   { bit offset in the packet and bit count of the tail }
    BlockFlag: Integer;
    CurPos, CurSub: Integer;      { Pos and Sub for the next events }
    procedure Add(aTag: TVbTag; aIsCode: Boolean; aCh, aPass: Integer; aBook: Integer; aVal: LongWord);
  end;

  TVbStatus = (vsOk, vsNotAudio, vsBadMode, vsBadCode, vsEop);

  { Where the walker gets its symbols from: the packet's bits when
    compressing, the model when decompressing. ev carries everything about
    the symbol except its value (Book is the codebook or the bit width). }
  TVbSource = class
    Status: TVbStatus;
    function Raw(const ev: TVbEvent): LongWord; virtual; abstract;
    function Code(const ev: TVbEvent): Integer; virtual; abstract;   { -1: failed, Status says why }
    function Eop: Boolean; virtual;
  end;

  TVbBitSource = class(TVbSource)
    Br: TBitReader;
    Setup: ^TVorbisSetup;
    function Raw(const ev: TVbEvent): LongWord; override;
    function Code(const ev: TVbEvent): Integer; override;
    function Eop: Boolean; override;
  end;

{ Header packets. Return False when the packet is not a valid header of
  that type (the stream is then left as bytes). }
function VorbisReadIdent(const a: TBytes; first, len: SizeInt; var s: TVorbisSetup): Boolean;
function VorbisReadSetup(const a: TBytes; first, len: SizeInt; var s: TVorbisSetup): Boolean;

function VorbisReadAudio(const s: TVorbisSetup; const a: TBytes; first, len: SizeInt;
  var p: TVbPacket): TVbStatus;

{ The packet structure, walked with symbols from src. Events go to p. The
  packet-type bit is not part of it (the caller handles it). }
function VorbisWalk(const s: TVorbisSetup; src: TVbSource; var p: TVbPacket): TVbStatus;

{ The packet's bytes from its events and its tail (taken from the original
  packet a[first..], since the tail is not modelled yet). }
function VorbisReencode(const s: TVorbisSetup; const p: TVbPacket;
  const a: TBytes; first, len: SizeInt): TBytes;

implementation

{ ---- codebooks ---- }

function TVorbisBook.Decode(var br: TBitReader): Integer;
var
  node, nx: Integer;
  b: LongWord;
begin
  if Length(Tree) = 0 then Exit(-1);
  node := 0;
  repeat
    b := br.Bit;
    if br.Eop then Exit(-1);
    nx := Tree[node][b];
    if nx = 0 then Exit(-1);
    if nx < 0 then Exit(-nx - 1);
    node := nx;
  until False;
end;

procedure TVorbisBook.Encode(var bw: TBitWriter; e: Integer);
var
  i: Integer;
begin
  for i := Lengths[e] - 1 downto 0 do
    bw.Bit((Codes[e] shr i) and 1);
end;

{ Codewords from lengths, the way the specification assigns them (lowest
  free codeword of each length, in entry order). False if the lengths
  over-fill the tree, or under-fill it with more than one entry. }
function MakeCodes(var bk: TVorbisBook): Boolean;
var
  marker: array[0..32] of LongWord;
  i, j, l, node, b: Integer;
  entry: LongWord;
begin
  Result := False;
  FillChar(marker, SizeOf(marker), 0);
  SetLength(bk.Codes, bk.Entries);
  bk.Used := 0;
  for i := 0 to bk.Entries - 1 do
  begin
    l := bk.Lengths[i];
    bk.Codes[i] := 0;
    if l = 0 then Continue;
    entry := marker[l];
    if (l < 32) and ((entry shr l) <> 0) then Exit;
    bk.Codes[i] := entry;
    Inc(bk.Used);
    for j := l downto 1 do
    begin
      if (marker[j] and 1) <> 0 then
      begin
        if j = 1 then Inc(marker[1])
        else marker[j] := marker[j - 1] shl 1;
        Break;
      end;
      Inc(marker[j]);
    end;
    for j := l + 1 to 32 do
      if (marker[j] shr 1) = entry then
      begin
        entry := marker[j];
        marker[j] := marker[j - 1] shl 1;
      end
      else
        Break;
  end;
  if bk.Used <> 1 then
    for i := 1 to 32 do
      if (marker[i] and ($FFFFFFFF shr (32 - i))) <> 0 then Exit;
  { the tree }
  SetLength(bk.Tree, 1);
  bk.Tree[0][0] := 0;
  bk.Tree[0][1] := 0;
  for i := 0 to bk.Entries - 1 do
  begin
    l := bk.Lengths[i];
    if l = 0 then Continue;
    node := 0;
    for j := l - 1 downto 0 do
    begin
      b := (bk.Codes[i] shr j) and 1;
      if j = 0 then
      begin
        if bk.Tree[node][b] <> 0 then Exit;
        bk.Tree[node][b] := -(i + 1);
      end
      else
      begin
        if bk.Tree[node][b] < 0 then Exit;
        if bk.Tree[node][b] = 0 then
        begin
          SetLength(bk.Tree, Length(bk.Tree) + 1);
          bk.Tree[High(bk.Tree)][0] := 0;
          bk.Tree[High(bk.Tree)][1] := 0;
          bk.Tree[node][b] := High(bk.Tree);
        end;
        node := bk.Tree[node][b];
      end;
    end;
  end;
  Result := True;
end;

function Lookup1Values(entries, dims: Integer): Integer;
var
  r, i: Integer;
  p: Int64;
begin
  r := 0;
  repeat
    Inc(r);
    p := 1;
    for i := 1 to dims do
    begin
      p := p * (r + 1);
      if p > entries then Break;
    end;
  until p > entries;
  Result := r;
end;

{ float32_unpack of the specification, as a fixed-point number in 1/16,
  clamped to +-2^20: exact integer arithmetic, so every platform agrees. }
function Unpack16(x: LongWord): Int64;
var
  mant: Int64;
  e: Integer;
begin
  mant := x and $1FFFFF;
  if (x and $80000000) <> 0 then mant := -mant;
  e := Integer((x and $7FE00000) shr 21) - 788 + 4;
  if e >= 0 then
  begin
    if e > 40 then e := 40;
    if Abs(mant) > (Int64(1) shl 21) then mant := 0;
    Result := mant * (Int64(1) shl e);
  end
  else if e > -63 then
  begin
    if mant >= 0 then Result := mant shr (-e) else Result := -((-mant) shr (-e));
  end
  else
    Result := 0;
  if Result > 1 shl 20 then Result := 1 shl 20;
  if Result < -(1 shl 20) then Result := -(1 shl 20);
end;

{ Whether an entry of a type 1 book is just its digits (Entries is
  exactly LookupValues^Dims), and the value of each digit. }
procedure BookGrid(var bk: TVorbisBook);
var
  i: Integer;
  p: Int64;
  mn, dl, v: Int64;
begin
  bk.Grid := False;
  if (bk.LookupType <> 1) or (bk.LookupValues < 2) or bk.SeqP then Exit;
  p := 1;
  for i := 1 to bk.Dims do
  begin
    p := p * bk.LookupValues;
    if p > bk.Entries then Exit;
  end;
  if p <> bk.Entries then Exit;
  mn := Unpack16(bk.MinV);
  dl := Unpack16(bk.DeltaV);
  SetLength(bk.ValQ, bk.LookupValues);
  for i := 0 to bk.LookupValues - 1 do
  begin
    v := mn + (dl * bk.Mult[i]) div 16;
    if v > 1 shl 20 then v := 1 shl 20;
    if v < -(1 shl 20) then v := -(1 shl 20);
    bk.ValQ[i] := v;
  end;
  bk.Grid := True;
end;

function ReadBook(var br: TBitReader; var bk: TVorbisBook): Boolean;
var
  i, cur, len, num: Integer;
  ordered, sparse: Boolean;
  vbits, nvals: Integer;
begin
  Result := False;
  if br.Read(24) <> $564342 then Exit;
  bk.Dims := br.Read(16);
  bk.Entries := br.Read(24);
  if (bk.Dims = 0) or (bk.Entries = 0) then Exit;
  SetLength(bk.Lengths, bk.Entries);
  ordered := br.Read(1) <> 0;
  if not ordered then
  begin
    sparse := br.Read(1) <> 0;
    for i := 0 to bk.Entries - 1 do
      if (not sparse) or (br.Read(1) <> 0) then
        bk.Lengths[i] := br.Read(5) + 1
      else
        bk.Lengths[i] := 0;
  end
  else
  begin
    cur := 0;
    len := br.Read(5) + 1;
    while cur < bk.Entries do
    begin
      num := br.Read(ILog(bk.Entries - cur));
      if (len > 32) or (cur + num > bk.Entries) then Exit;
      for i := cur to cur + num - 1 do
        bk.Lengths[i] := len;
      Inc(cur, num);
      Inc(len);
      if br.Eop then Exit;
    end;
  end;
  bk.LookupType := br.Read(4);
  case bk.LookupType of
    0: ;
    1, 2:
      begin
        bk.MinV := br.Read(32);
        bk.DeltaV := br.Read(32);
        vbits := br.Read(4) + 1;
        bk.SeqP := br.Read(1) <> 0;
        if bk.LookupType = 1 then
          nvals := Lookup1Values(bk.Entries, bk.Dims)
        else
          nvals := bk.Entries * bk.Dims;
        if nvals > 1 shl 20 then Exit;
        bk.LookupValues := nvals;
        SetLength(bk.Mult, nvals);
        for i := 0 to nvals - 1 do
        begin
          bk.Mult[i] := br.Read(vbits);
          if br.Eop then Exit;
        end;
      end;
  else
    Exit;
  end;
  if br.Eop then Exit;
  Result := MakeCodes(bk);
  if Result then BookGrid(bk);
end;

{ ---- headers ---- }

function CheckSig(const a: TBytes; first, len: SizeInt; typ: Byte): Boolean;
const
  S = 'vorbis';
var
  i: Integer;
begin
  Result := (len >= 7) and (a[first] = typ);
  if Result then
    for i := 1 to 6 do
      if a[first + i] <> Ord(S[i]) then Exit(False);
end;

function VorbisReadIdent(const a: TBytes; first, len: SizeInt; var s: TVorbisSetup): Boolean;
var
  br: TBitReader;
  b0, b1: Integer;
begin
  Result := False;
  s.HaveIdent := False;
  s.HaveSetup := False;
  if (len < 30) or not CheckSig(a, first, len, 1) then Exit;
  br.Init(a, first + 7, len - 7);
  if br.Read(32) <> 0 then Exit;
  s.Channels := br.Read(8);
  s.Rate := br.Read(32);
  br.Read(32); br.Read(32); br.Read(32);
  b0 := br.Read(4);
  b1 := br.Read(4);
  if (s.Channels = 0) or (s.Rate = 0) or (b0 < 6) or (b0 > 13) or (b1 < b0) or (b1 > 13) then Exit;
  if br.Read(1) <> 1 then Exit;
  s.Block0 := 1 shl b0;
  s.Block1 := 1 shl b1;
  s.HaveIdent := True;
  Result := True;
end;

{ The neighbours of each post and the posts in X order; False if two posts
  share an X (the specification forbids it). }
function Floor1Prepare(var f: TFloor1): Boolean;
var
  i, j, lo, hi, t: Integer;
begin
  Result := False;
  case f.Multiplier of
    1: f.Range := 256;
    2: f.Range := 128;
    3: f.Range := 86;
  else
    f.Range := 64;
  end;
  SetLength(f.LowN, Length(f.X));
  SetLength(f.HighN, Length(f.X));
  for i := 0 to High(f.X) do
    for j := 0 to i - 1 do
      if f.X[j] = f.X[i] then Exit;
  for i := 2 to High(f.X) do
  begin
    lo := -1;
    hi := -1;
    for j := 0 to i - 1 do
    begin
      if (f.X[j] < f.X[i]) and ((lo < 0) or (f.X[j] > f.X[lo])) then lo := j;
      if (f.X[j] > f.X[i]) and ((hi < 0) or (f.X[j] < f.X[hi])) then hi := j;
    end;
    if (lo < 0) or (hi < 0) then Exit;
    f.LowN[i] := lo;
    f.HighN[i] := hi;
  end;
  SetLength(f.Sorted, Length(f.X));
  for i := 0 to High(f.X) do f.Sorted[i] := i;
  for i := 1 to High(f.Sorted) do
  begin
    t := f.Sorted[i];
    j := i - 1;
    while (j >= 0) and (f.X[f.Sorted[j]] > f.X[t]) do
    begin
      f.Sorted[j + 1] := f.Sorted[j];
      Dec(j);
    end;
    f.Sorted[j + 1] := t;
  end;
  Result := True;
end;

function VorbisReadSetup(const a: TBytes; first, len: SizeInt; var s: TVorbisSetup): Boolean;
var
  br: TBitReader;
  n, i, j, k, maxClass, cls, cnt, low, hi: Integer;
  casc: array of Integer;
begin
  Result := False;
  s.HaveSetup := False;
  if not s.HaveIdent or not CheckSig(a, first, len, 5) then Exit;
  br.Init(a, first + 7, len - 7);

  n := br.Read(8) + 1;
  SetLength(s.Books, n);
  for i := 0 to n - 1 do
    if not ReadBook(br, s.Books[i]) then Exit;

  n := br.Read(6) + 1;
  for i := 1 to n do
    if br.Read(16) <> 0 then Exit;

  n := br.Read(6) + 1;
  SetLength(s.Floors, n);
  for i := 0 to n - 1 do
    with s.Floors[i] do
    begin
      FType := br.Read(16);
      case FType of
        0:
          with F0 do
          begin
            Order := br.Read(8);
            Rate := br.Read(16);
            BarkMapSize := br.Read(16);
            AmpBits := br.Read(6);
            AmpOffset := br.Read(8);
            SetLength(Books, br.Read(4) + 1);
            for j := 0 to High(Books) do
            begin
              Books[j] := br.Read(8);
              if Books[j] >= Length(s.Books) then Exit;
            end;
            if (Order = 0) or (AmpBits = 0) then Exit;
          end;
        1:
          with F1 do
          begin
            Partitions := br.Read(5);
            SetLength(PartClass, Partitions);
            maxClass := -1;
            for j := 0 to Partitions - 1 do
            begin
              PartClass[j] := br.Read(4);
              if PartClass[j] > maxClass then maxClass := PartClass[j];
            end;
            SetLength(ClassDim, maxClass + 1);
            SetLength(ClassSub, maxClass + 1);
            SetLength(ClassMaster, maxClass + 1);
            SetLength(SubBooks, maxClass + 1);
            for j := 0 to maxClass do
            begin
              ClassDim[j] := br.Read(3) + 1;
              ClassSub[j] := br.Read(2);
              ClassMaster[j] := -1;
              if ClassSub[j] > 0 then
              begin
                ClassMaster[j] := br.Read(8);
                if ClassMaster[j] >= Length(s.Books) then Exit;
              end;
              SetLength(SubBooks[j], 1 shl ClassSub[j]);
              for k := 0 to High(SubBooks[j]) do
              begin
                SubBooks[j][k] := Integer(br.Read(8)) - 1;
                if SubBooks[j][k] >= Length(s.Books) then Exit;
              end;
            end;
            Multiplier := br.Read(2) + 1;
            RangeBits := br.Read(4);
            SetLength(X, 2);
            X[0] := 0;
            X[1] := 1 shl RangeBits;
            for j := 0 to Partitions - 1 do
            begin
              cls := PartClass[j];
              for k := 1 to ClassDim[cls] do
              begin
                SetLength(X, Length(X) + 1);
                X[High(X)] := br.Read(RangeBits);
              end;
            end;
            if Length(X) > 65 then Exit;
            if not Floor1Prepare(F1) then Exit;
          end;
      else
        Exit;
      end;
      if br.Eop then Exit;
    end;

  n := br.Read(6) + 1;
  SetLength(s.Residues, n);
  for i := 0 to n - 1 do
    with s.Residues[i] do
    begin
      RType := br.Read(16);
      if RType > 2 then Exit;
      RBegin := br.Read(24);
      REnd := br.Read(24);
      PartSize := br.Read(24) + 1;
      Classes := br.Read(6) + 1;
      ClassBook := br.Read(8);
      if ClassBook >= Length(s.Books) then Exit;
      SetLength(casc, Classes);
      for j := 0 to Classes - 1 do
      begin
        low := br.Read(3);
        hi := 0;
        if br.Read(1) <> 0 then hi := br.Read(5);
        casc[j] := hi * 8 + low;
      end;
      SetLength(Books, Classes);
      for j := 0 to Classes - 1 do
        for k := 0 to 7 do
          if (casc[j] and (1 shl k)) <> 0 then
          begin
            Books[j][k] := br.Read(8);
            if Books[j][k] >= Length(s.Books) then Exit;
          end
          else
            Books[j][k] := -1;
      if br.Eop then Exit;
    end;

  n := br.Read(6) + 1;
  SetLength(s.Mappings, n);
  for i := 0 to n - 1 do
    with s.Mappings[i] do
    begin
      if br.Read(16) <> 0 then Exit;
      if br.Read(1) <> 0 then Submaps := br.Read(4) + 1 else Submaps := 1;
      CouplingSteps := 0;
      if br.Read(1) <> 0 then
      begin
        CouplingSteps := br.Read(8) + 1;
        SetLength(Magnitude, CouplingSteps);
        SetLength(Angle, CouplingSteps);
        for j := 0 to CouplingSteps - 1 do
        begin
          Magnitude[j] := br.Read(ILog(s.Channels - 1));
          Angle[j] := br.Read(ILog(s.Channels - 1));
          if (Magnitude[j] = Angle[j]) or (Magnitude[j] >= s.Channels) or
             (Angle[j] >= s.Channels) then Exit;
        end;
      end;
      if br.Read(2) <> 0 then Exit;
      SetLength(Mux, s.Channels);
      for j := 0 to s.Channels - 1 do
        if Submaps > 1 then
        begin
          Mux[j] := br.Read(4);
          if Mux[j] >= Submaps then Exit;
        end
        else
          Mux[j] := 0;
      SetLength(SubFloor, Submaps);
      SetLength(SubResidue, Submaps);
      for j := 0 to Submaps - 1 do
      begin
        br.Read(8);
        SubFloor[j] := br.Read(8);
        SubResidue[j] := br.Read(8);
        if (SubFloor[j] >= Length(s.Floors)) or (SubResidue[j] >= Length(s.Residues)) then Exit;
      end;
      if br.Eop then Exit;
    end;

  n := br.Read(6) + 1;
  SetLength(s.Modes, n);
  for i := 0 to n - 1 do
    with s.Modes[i] do
    begin
      BlockFlag := br.Read(1);
      if br.Read(16) <> 0 then Exit;
      if br.Read(16) <> 0 then Exit;
      Mapping := br.Read(8);
      if Mapping >= Length(s.Mappings) then Exit;
    end;
  if br.Read(1) <> 1 then Exit;
  if br.Eop then Exit;
  s.ModeBits := ILog(Length(s.Modes) - 1);
  cnt := 0;
  if cnt <> 0 then Exit;
  s.HaveSetup := True;
  Result := True;
end;

{ ---- audio packets ---- }

procedure TVbPacket.Add(aTag: TVbTag; aIsCode: Boolean; aCh, aPass: Integer; aBook: Integer; aVal: LongWord);
begin
  if Count >= Length(Events) then
    SetLength(Events, 2 * Length(Events) + 256);
  with Events[Count] do
  begin
    Tag := aTag;
    IsCode := aIsCode;
    Ch := aCh;
    Pass := aPass;
    Book := aBook;
    Val := aVal;
    Pos := CurPos;
    Sub := CurSub;
  end;
  Inc(Count);
end;

function TVbSource.Eop: Boolean;
begin
  Result := False;
end;

function TVbBitSource.Raw(const ev: TVbEvent): LongWord;
begin
  Result := Br.Read(ev.Book);
end;

function TVbBitSource.Code(const ev: TVbEvent): Integer;
begin
  Result := Setup^.Books[ev.Book].Decode(Br);
  if Result < 0 then
    if Br.Eop then Status := vsEop else Status := vsBadCode;
end;

function TVbBitSource.Eop: Boolean;
begin
  Result := Br.Eop;
end;

function VorbisReadAudio(const s: TVorbisSetup; const a: TBytes; first, len: SizeInt;
  var p: TVbPacket): TVbStatus;
var
  src: TVbBitSource;
begin
  p.Count := 0;
  p.TailPos := 0;
  p.TailBits := 0;
  if not s.HaveSetup or (len = 0) then Exit(vsNotAudio);
  src := TVbBitSource.Create;
  try
    src.Setup := @s;
    src.Br.Init(a, first, len);
    if src.Br.Read(1) <> 0 then Exit(vsNotAudio);
    Result := VorbisWalk(s, src, p);
    if Result = vsOk then
    begin
      p.TailPos := src.Br.Pos;
      p.TailBits := len * 8 - src.Br.Pos;
    end;
  finally
    src.Free;
  end;
end;

function VorbisWalk(const s: TVorbisSetup; src: TVbSource; var p: TVbPacket): TVbStatus;
var
  mode, ch, i, j, k, sm, yi, part, cls, cdim, cbits, csub, cval, book, rng, ybits: Integer;
  m: ^TMapping;
  fl: ^TFloor;
  noRes: array[0..VB_MAX_CH] of Boolean;
  bs: Integer;
  status: TVbStatus;
  ev: TVbEvent;

  procedure Prep(tag: TVbTag; isCode: Boolean; c, pass, b: Integer);
  begin
    ev.Tag := tag;
    ev.IsCode := isCode;
    ev.Ch := c;
    ev.Pass := pass;
    ev.Book := b;
    ev.Pos := p.CurPos;
    ev.Sub := p.CurSub;
    ev.Val := 0;
  end;

  function Raw(tag: TVbTag; c, pass, n: Integer): LongWord;
  begin
    Prep(tag, False, c, pass, n);
    Result := src.Raw(ev);
    p.Add(tag, False, c, pass, n, Result);
  end;

  function Code(tag: TVbTag; c, pass, b: Integer): Integer;
  begin
    Prep(tag, True, c, pass, b);
    Result := src.Code(ev);
    if Result < 0 then
    begin
      status := src.Status;
      Exit;
    end;
    p.Add(tag, True, c, pass, b, Result);
  end;

  { One residue vector set: chans are the channels decoded together,
    n the length of each vector. For type 2 the caller passes a single
    channel and n already multiplied. }
  function DecodeResidue(const r: TResidue; const chans: array of Integer;
    const dnd: array of Boolean; n: Integer): Boolean;
  var
    lb, le, toRead, parts, cpc, pass, pc, c, t, q, vb, cnt, bk, step, cw: Integer;
    cls: array of array of Integer;
    e: Integer;
  begin
    Result := False;
    lb := r.RBegin; if lb > n then lb := n;
    le := r.REnd; if le > n then le := n;
    if le <= lb then Exit(True);
    toRead := le - lb;
    parts := toRead div r.PartSize;
    cpc := s.Books[r.ClassBook].Dims;
    SetLength(cls, Length(chans), parts + cpc);
    for pass := 0 to 7 do
    begin
      pc := 0;
      while pc < parts do
      begin
        if pass = 0 then
          for c := 0 to High(chans) do
            if not dnd[c] then
            begin
              p.CurPos := pc;
              p.CurSub := 0;
              e := Code(vtResClass, chans[c], 0, r.ClassBook);
              if e < 0 then Exit;
              t := e;
              for q := cpc - 1 downto 0 do
              begin
                cls[c][q + pc] := t mod r.Classes;
                t := t div r.Classes;
              end;
            end;
        q := 0;
        while (q < cpc) and (pc < parts) do
        begin
          for c := 0 to High(chans) do
            if not dnd[c] then
            begin
              vb := cls[c][pc];
              bk := r.Books[vb][pass];
              if bk >= 0 then
              begin
                step := s.Books[bk].Dims;
                if r.RType = 0 then
                  cnt := r.PartSize div step
                else
                  cnt := (r.PartSize + step - 1) div step;
                p.CurPos := pc;
                for cw := 1 to cnt do
                begin
                  p.CurSub := cw - 1;
                  if Code(vtResVec, chans[c], pass, bk) < 0 then Exit;
                end;
              end;
            end;
          Inc(q);
          Inc(pc);
        end;
      end;
    end;
    Result := True;
  end;

var
  chans: array of Integer;
  dnd: array of Boolean;
  allDnd: Boolean;
  r: ^TResidue;
begin
  p.Count := 0;
  p.CurPos := 0;
  p.CurSub := 0;
  status := vsOk;
  mode := Raw(vtMode, 0, 0, s.ModeBits);
  if src.Eop then Exit(vsEop);
  if mode >= Length(s.Modes) then Exit(vsBadMode);
  p.BlockFlag := s.Modes[mode].BlockFlag;
  if p.BlockFlag <> 0 then
  begin
    Raw(vtWinPrev, 0, 0, 1);
    Raw(vtWinNext, 0, 0, 1);
    bs := s.Block1;
  end
  else
    bs := s.Block0;
  m := @s.Mappings[s.Modes[mode].Mapping];

  { floors }
  for ch := 0 to s.Channels - 1 do
  begin
    fl := @s.Floors[m^.SubFloor[m^.Mux[ch]]];
    noRes[ch] := True;
    if fl^.FType = 1 then
      with fl^.F1 do
      begin
        if Raw(vtFloorNZ, ch, 0, 1) = 0 then Continue;
        case Multiplier of
          1: rng := 256;
          2: rng := 128;
          3: rng := 86;
        else
          rng := 64;
        end;
        ybits := ILog(rng - 1);
        p.CurPos := 0;
        Raw(vtFloorY0, ch, 0, ybits);
        p.CurPos := 1;
        Raw(vtFloorY1, ch, 0, ybits);
        yi := 2;
        for part := 0 to Partitions - 1 do
        begin
          cls := PartClass[part];
          cdim := ClassDim[cls];
          cbits := ClassSub[cls];
          csub := (1 shl cbits) - 1;
          cval := 0;
          p.CurPos := part;
          if cbits > 0 then
          begin
            cval := Code(vtFloorMaster, ch, cls, ClassMaster[cls]);
            if cval < 0 then Exit(status);
          end;
          for j := 0 to cdim - 1 do
          begin
            book := SubBooks[cls][cval and csub];
            cval := cval shr cbits;
            p.CurPos := yi;
            Inc(yi);
            if book >= 0 then
              if Code(vtFloorY, ch, cls, book) < 0 then Exit(status);
          end;
        end;
        if src.Eop then Exit(vsEop);
        noRes[ch] := False;
      end
    else
      with fl^.F0 do
      begin
        p.CurPos := 0;
        if Raw(vtF0Amp, ch, 0, AmpBits) = 0 then Continue;
        k := Raw(vtF0Book, ch, 0, ILog(Length(Books)));
        if src.Eop then Exit(vsEop);
        if k >= Length(Books) then Exit(vsBadCode);
        book := Books[k];
        i := 0;
        while i < Order do
        begin
          p.CurPos := i;
          if Code(vtF0Vec, ch, 0, book) < 0 then Exit(status);
          Inc(i, s.Books[book].Dims);
        end;
        noRes[ch] := False;
      end;
  end;

  { coupled channels decode together }
  for i := 0 to m^.CouplingSteps - 1 do
    if not noRes[m^.Magnitude[i]] or not noRes[m^.Angle[i]] then
    begin
      noRes[m^.Magnitude[i]] := False;
      noRes[m^.Angle[i]] := False;
    end;

  { residues }
  for sm := 0 to m^.Submaps - 1 do
  begin
    chans := nil;
    dnd := nil;
    for ch := 0 to s.Channels - 1 do
      if m^.Mux[ch] = sm then
      begin
        SetLength(chans, Length(chans) + 1);
        SetLength(dnd, Length(dnd) + 1);
        chans[High(chans)] := ch;
        dnd[High(dnd)] := noRes[ch];
      end;
    if Length(chans) = 0 then Continue;
    r := @s.Residues[m^.SubResidue[sm]];
    if r^.RType = 2 then
    begin
      allDnd := True;
      for j := 0 to High(dnd) do
        if not dnd[j] then allDnd := False;
      if allDnd then Continue;
      if not DecodeResidue(r^, [chans[0]], [False], (bs div 2) * Length(chans)) then Exit(status);
    end
    else if not DecodeResidue(r^, chans, dnd, bs div 2) then Exit(status);
  end;

  if src.Eop then Exit(vsEop);
  Result := vsOk;
end;

function VorbisReencode(const s: TVorbisSetup; const p: TVbPacket;
  const a: TBytes; first, len: SizeInt): TBytes;
var
  bw: TBitWriter;
  br: TBitReader;
  i: SizeInt;
begin
  bw.Init;
  bw.Bit(0);
  for i := 0 to p.Count - 1 do
    with p.Events[i] do
      if IsCode then
        s.Books[Book].Encode(bw, Val)
      else
        bw.Write(Val, Book);
  br.Init(a, first, len);
  br.Pos := p.TailPos;
  for i := 1 to p.TailBits do
    bw.Bit(br.Bit);
  Result := bw.Bytes;
end;

end.
