{ Ported from PJA's pas/pjainfo.pas via PMPA (pas/pmpainfo.pas).

  What a file is and what POA does with it, for the command's info, report
  and --json (doc/CLI.md).

  A description is a tree (TInfoNode) that prints as indented text or as
  one line of JSON. Each format has its provider: a probe that says the
  bytes are its own, and a describe that fills the tree from the file's
  structure (poainfopoa: the .poa's header; poainfoogg: the Ogg container,
  its logical streams, pages and gaps). A unit registers its provider when
  it starts; the first whose probe says yes describes the file. A new
  format is a new unit and a line in the program's uses.

  Nothing here prints what a file holds: no audio, no text of its comment
  headers. A provider gives sizes, places, counts and codecs.
}
unit poainfo;

{$I poa.inc}
{$ifopt R-}{$fatal poainfo: range checks ($R+) are mandatory}{$endif}
{$ifopt Q-}{$fatal poainfo: overflow checks ($Q+) are mandatory}{$endif}

interface

uses SysUtils, Classes;

type
  TInfoKind = (ikObject, ikList, ikText, ikNumber, ikBool);

  TInfoNode = class
  public
    kind: TInfoKind;
    { its name in the object that holds it ('' in a list) }
    key: string;
    { text, a number written out, or true / false }
    value: string;
    { an object in a list: how it prints as text, on one line ('' prints
      its fields under a dash) }
    line: string;
    items: array of TInfoNode;
    constructor Create(k: TInfoKind; const name: string = '');
    destructor Destroy; override;
    function Add(n: TInfoNode): TInfoNode;
    { an object or a list under this object (or, with name '', an item of
      this list) }
    function Obj(const name: string = ''): TInfoNode;
    function List(const name: string): TInfoNode;
    procedure Str(const name, v: string);
    procedure Num(const name: string; v: Int64);
    procedure Fixed(const name: string; v: Double; digits: Integer = 2);
    procedure Bool(const name: string; v: Boolean);
    { the child of that name, or nil }
    function Find(const name: string): TInfoNode;
    { JSON, on one line }
    function Json: string;
    { indented text, one line per field }
    procedure Render(lines: TStrings; indent: Integer = 0);
  end;

  { the bytes are this format's }
  TInfoProbe = function(const d: TBytes): Boolean;
  { its structure into n }
  TInfoDescribe = procedure(const d: TBytes; n: TInfoNode);

  { how much work info and report do for what POA does with a file:
    idDefault (info, report): `a`'s dry run, which takes about what `a`
    takes. idStructure (report on a file above REPORT_ESTIMATE_MAX): no dry
    run at all, with a note. }
  TInfoDepth = (idDefault, idStructure);

const
  { report: above this, no dry run (idStructure) }
  REPORT_ESTIMATE_MAX = 64 * 1024 * 1024;

var
  { the largest original a provider decodes anything of (x's --max-output;
    DescribeFile sets it): a .poa that declares more is not decoded, as x
    refuses it, however little it holds }
  InfoMaxOutput: QWord = High(QWord);
  { the depth of this description (DescribeFile sets it) }
  InfoDepth: TInfoDepth = idDefault;

{ A format's provider, tried in the order they were registered. }
procedure RegisterInfoProvider(const name: string; probe: TInfoProbe; describe: TInfoDescribe);
{ The file's structure into n by its provider; n says format unknown when
  none takes it. The name of the provider, or ''. }
function DescribeData(const d: TBytes; n: TInfoNode): string;
{ What POA does with the file: for a .poa, whether it extracts and
  verifies (maxOutput as x's --max-output); for anything else, whether `a`
  takes it, with which stream and what size, or stored as is, or why not.
  verify: as `a` without --no-verify (a stream that does not come back
  raises EPoaVerify, a bug). One line of text in `line`. }
procedure DescribeAction(const d: TBytes; verify: Boolean; maxOutput: QWord; depth: TInfoDepth; n: TInfoNode;
                         out line: string);
{ A file for `poa info` and `poa report`: its name, then its structure
  (DescribeData), then what POA does with it, as "poa" (DescribeAction).
  The caller frees it. }
function DescribeFile(const name: string; const d: TBytes; verify: Boolean; maxOutput: QWord;
                      depth: TInfoDepth): TInfoNode;
{ a string for JSON, quoted; bytes that are not UTF-8 go as \u00XX }
function JsonString(const s: string): string;
{ 128 bits as 32 hex digits }
function HexBytes(const b: array of Byte): string;
{ "1748 B", "15.3 KB", "12.0 MB" }
function HumanSize(n: QWord): string;
{ a number with a dot, whatever the locale }
function DotNumber(v: Double; digits: Integer): string;

implementation

uses poablake3, poaformat, poapack;

type
  TProvider = record
    name: string;
    probe: TInfoProbe;
    describe: TInfoDescribe;
  end;

var
  providers: array of TProvider;

function DotNumber(v: Double; digits: Integer): string;
var fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  fs.ThousandSeparator := #0;
  Result := FloatToStrF(v, ffFixed, 18, digits, fs);
end;

function HumanSize(n: QWord): string;
begin
  if n >= 10 * 1024 * 1024 then Result := DotNumber(n / (1024 * 1024), 1) + ' MB'
  else if n >= 10 * 1024 then Result := DotNumber(n / 1024, 1) + ' KB'
  else Result := IntToStr(n) + ' B';
end;

function HexBytes(const b: array of Byte): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(b) do Result := Result + LowerCase(IntToHex(b[i], 2));
end;

{ the length of the UTF-8 sequence at s[i], 0 if there is none }
function Utf8Len(const s: string; i: Integer): Integer;
var c: Byte; k, n: Integer;
begin
  c := Ord(s[i]);
  if c < $80 then Exit(1);
  if (c >= $C2) and (c <= $DF) then n := 2
  else if (c >= $E0) and (c <= $EF) then n := 3
  else if (c >= $F0) and (c <= $F4) then n := 4
  else Exit(0);
  if i + n - 1 > Length(s) then Exit(0);
  for k := 1 to n - 1 do
    if Ord(s[i + k]) and $C0 <> $80 then Exit(0);
  Result := n;
end;

function JsonString(const s: string): string;
var i, n: Integer; c: Char;
begin
  Result := '"';
  i := 1;
  while i <= Length(s) do begin
    c := s[i];
    case c of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8: Result := Result + '\b';
      #9: Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
      #0..#7, #11, #14..#31, #127: Result := Result + '\u00' + LowerCase(IntToHex(Ord(c), 2));
    else
      n := Utf8Len(s, i);
      if n = 0 then Result := Result + '\u00' + LowerCase(IntToHex(Ord(c), 2))
      else begin
        Result := Result + Copy(s, i, n);
        Inc(i, n);
        Continue;
      end;
    end;
    Inc(i);
  end;
  Result := Result + '"';
end;

{ ---------- TInfoNode ---------- }

constructor TInfoNode.Create(k: TInfoKind; const name: string);
begin
  inherited Create;
  kind := k;
  key := name;
end;

destructor TInfoNode.Destroy;
var i: Integer;
begin
  for i := 0 to High(items) do items[i].Free;
  inherited Destroy;
end;

function TInfoNode.Add(n: TInfoNode): TInfoNode;
var k: Integer;
begin
  { a field given twice keeps the last value }
  if (kind = ikObject) and (n.key <> '') then
    for k := 0 to High(items) do
      if items[k].key = n.key then begin
        items[k].Free;
        items[k] := n;
        Exit(n);
      end;
  SetLength(items, Length(items) + 1);
  items[High(items)] := n;
  Result := n;
end;

function TInfoNode.Obj(const name: string): TInfoNode;
begin
  Result := Add(TInfoNode.Create(ikObject, name));
end;

function TInfoNode.List(const name: string): TInfoNode;
begin
  Result := Add(TInfoNode.Create(ikList, name));
end;

procedure TInfoNode.Str(const name, v: string);
begin
  Add(TInfoNode.Create(ikText, name)).value := v;
end;

procedure TInfoNode.Num(const name: string; v: Int64);
begin
  Add(TInfoNode.Create(ikNumber, name)).value := IntToStr(v);
end;

procedure TInfoNode.Fixed(const name: string; v: Double; digits: Integer);
begin
  Add(TInfoNode.Create(ikNumber, name)).value := DotNumber(v, digits);
end;

procedure TInfoNode.Bool(const name: string; v: Boolean);
begin
  if v then Add(TInfoNode.Create(ikBool, name)).value := 'true'
  else Add(TInfoNode.Create(ikBool, name)).value := 'false';
end;

function TInfoNode.Find(const name: string): TInfoNode;
var k: Integer;
begin
  Result := nil;
  for k := 0 to High(items) do
    if items[k].key = name then Exit(items[k]);
end;

function TInfoNode.Json: string;
var k: Integer;
begin
  case kind of
    ikText: Result := JsonString(value);
    ikNumber, ikBool: Result := value;
    ikList: begin
      Result := '[';
      for k := 0 to High(items) do begin
        if k > 0 then Result := Result + ',';
        Result := Result + items[k].Json;
      end;
      Result := Result + ']';
    end;
  else
    Result := '{';
    for k := 0 to High(items) do begin
      if k > 0 then Result := Result + ',';
      Result := Result + JsonString(items[k].key) + ':' + items[k].Json;
    end;
    Result := Result + '}';
  end;
end;

procedure TInfoNode.Render(lines: TStrings; indent: Integer);
var k: Integer; pad: string; it: TInfoNode;
begin
  pad := StringOfChar(' ', indent);
  for k := 0 to High(items) do begin
    it := items[k];
    if kind = ikList then begin
      if (it.kind = ikObject) and (it.line = '') then begin
        lines.Add(pad + '-');
        it.Render(lines, indent + 2);
      end else if it.kind = ikObject then lines.Add(pad + '- ' + it.line)
      else if it.kind in [ikObject, ikList] then begin
        lines.Add(pad + '-');
        it.Render(lines, indent + 2);
      end else lines.Add(pad + '- ' + it.value);
    end else if it.kind in [ikObject, ikList] then begin
      if (it.kind = ikObject) and (it.line <> '') then lines.Add(pad + it.key + ': ' + it.line)
      else if Length(it.items) = 0 then lines.Add(pad + it.key + ': (none)')
      else begin
        lines.Add(pad + it.key + ':');
        it.Render(lines, indent + 2);
      end;
    end else lines.Add(pad + it.key + ': ' + it.value);
  end;
end;

{ ---------- providers ---------- }

procedure RegisterInfoProvider(const name: string; probe: TInfoProbe; describe: TInfoDescribe);
begin
  SetLength(providers, Length(providers) + 1);
  providers[High(providers)].name := name;
  providers[High(providers)].probe := probe;
  providers[High(providers)].describe := describe;
end;

function DescribeData(const d: TBytes; n: TInfoNode): string;
var k: Integer;
begin
  Result := '';
  for k := 0 to High(providers) do
    if providers[k].probe(d) then begin
      providers[k].describe(d, n);
      Exit(providers[k].name);
    end;
  n.Str('format', 'unknown');
  n.Num('size', Length(d));
end;

{ ---------- what POA does ---------- }

procedure DescribeAction(const d: TBytes; verify: Boolean; maxOutput: QWord; depth: TInfoDepth; n: TInfoNode;
                         out line: string);
var poa, orig: TBytes; r: TPackResult; h: THash16;
begin
  if PoaIsPoa(d) then begin
    n.Str('command', 'x');
    r := Unpack(d, maxOutput, orig, h);
    n.Bool('ok', r.Ok);
    if r.Ok then begin
      n.Num('original_size', Length(orig));
      line := 'extracts it: ' + IntToStr(Length(orig)) + ' B, size and BLAKE3-128 verified';
    end else begin
      n.Str('error', r.Text);
      line := 'does not extract it: ' + r.Text;
    end;
    Exit;
  end;
  n.Str('command', 'a');
  if depth = idStructure then begin
    n.Bool('estimated', False);
    line := 'not estimated: the file is larger than ' + IntToStr(REPORT_ESTIMATE_MAX div (1024 * 1024)) +
            ' MB (poa info does the dry run)';
    Exit;
  end;
  n.Bool('estimated', True);
  r := Pack(d, poa, verify);
  n.Bool('ok', r.Ok);
  if not r.Ok then begin
    n.Bool('takes', False);
    n.Str('error', r.Text);
    line := 'refuses it: ' + r.Text;
    Exit;
  end;
  n.Bool('takes', True);
  n.Bool('stored', r.stored);
  n.Num('poa_size', Length(poa));
  if Length(d) > 0 then n.Fixed('ratio_percent', 100 * Length(poa) / Length(d));
  n.Num('streams', r.stats.Streams);
  n.Num('pages', r.stats.Pages);
  n.Num('gaps', r.stats.Gaps);
  n.Num('vorbis_packets_modelled', r.stats.VorbisEvents);
  n.Num('packets_as_bytes', r.stats.VorbisRaw + r.stats.OtherPackets);
  if r.stored then line := 'takes it: stored as is (the coded stream would not be smaller), '
  else line := 'takes it: ';
  line := line + IntToStr(Length(d)) + ' B -> ' + IntToStr(Length(poa)) + ' B';
  if Length(d) > 0 then line := line + ' (' + DotNumber(100 * Length(poa) / Length(d), 2) + '%)';
  line := line + ', ' + IntToStr(r.stats.VorbisEvents) + ' Vorbis packets modelled, ' +
          IntToStr(r.stats.VorbisRaw + r.stats.OtherPackets) + ' as bytes';
end;

function DescribeFile(const name: string; const d: TBytes; verify: Boolean; maxOutput: QWord;
                      depth: TInfoDepth): TInfoNode;
var act: TInfoNode; summary: string;
begin
  Result := TInfoNode.Create(ikObject);
  Result.Str('file', name);
  InfoMaxOutput := maxOutput;
  InfoDepth := depth;
  { a bug met here is what a report is for: it goes in the description,
    as internal_error, instead of ending the command }
  try
    DescribeData(d, Result);
  except
    on e: Exception do Result.Str('internal_error', 'describing it: ' + e.ClassName + ': ' + e.Message);
  end;
  act := TInfoNode.Create(ikObject, 'poa');
  try
    DescribeAction(d, verify, maxOutput, depth, act, summary);
  except
    on e: Exception do begin
      summary := 'internal error: ' + e.ClassName + ': ' + e.Message;
      Result.Str('internal_error', e.ClassName + ': ' + e.Message);
    end;
  end;
  act.line := summary;
  act.Str('summary', summary);
  Result.Add(act);
end;

end.
