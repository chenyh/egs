%	EGS: Erlang Game Server
%	Copyright (C) 2010  Loic Hoguin
%
%	This file is part of EGS.
%
%	EGS is free software: you can redistribute it and/or modify
%	it under the terms of the GNU General Public License as published by
%	the Free Software Foundation, either version 3 of the License, or
%	(at your option) any later version.
%
%	EGS is distributed in the hope that it will be useful,
%	but WITHOUT ANY WARRANTY; without even the implied warranty of
%	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%	GNU General Public License for more details.
%
%	You should have received a copy of the GNU General Public License
%	along with EGS.  If not, see <http://www.gnu.org/licenses/>.

-module(psu_parser).
-export([run/0]).

-include("include/maps.hrl").

-define(NBL, "./nbl").

run() ->
	List = [{QuestID, parse_quest(QuestID)} || {QuestID, _} <- ?QUESTS],
	Begin = "%% This file is automatically generated by EGS.
%% Please do not edit it manually, as you would risk losing your changes.

-define(MISSIONS,
",
	End = ").
",
	Missions = io_lib:format("~s~p~s", [Begin, List, End]),
	file:write_file("include/missions.hrl", Missions).

parse_quest(QuestID) ->
	[{ZoneID, parse_zone(Filename)} || {[ZoneQuestID, ZoneID], [{file, Filename}|_]} <- ?ZONES, ZoneQuestID =:= QuestID].

parse_zone(NblFilename) ->
	Files = nbl_list_files(NblFilename),
	log("~p", [Files]),
	nbl_extract_files(NblFilename),
	Filename = "set_r0.rel",
	case filelib:is_file(io_lib:format("tmp/~s", [Filename])) of
		false ->
			io:format("ignoring ~s (no set file)~n", [NblFilename]),
			nbl_cleanup(),
			[];
		true ->
			io:format("parsing ~s~n", [NblFilename]),
			BasePtr = calc_base_ptr(Filename, Files, 0),
			{ok, << $N, $X, $R, 0, EndRelPtr:32/little-unsigned-integer, AreaIDListRelPtr:32/little-unsigned-integer, 0:32, Data/bits >>} = file:read_file(io_lib:format("tmp/~s", [Filename])),
			log("header: end ptr(~b) areaid list ptr(~b)", [EndRelPtr, AreaIDListRelPtr]),
			{ok, _AreaCode, NbMaps, MapsListPtr} = parse_areaid_list(Data, AreaIDListRelPtr - 16),
			MapList = parse_mapnumbers_list(Data, NbMaps, MapsListPtr - BasePtr - 16),
			ObjList = [{MapID, parse_object_list_headers(BasePtr, Data, NbHeaders, ObjListHeadersPtr - BasePtr - 16)} || {MapID, NbHeaders, ObjListHeadersPtr} <- MapList],
			nbl_cleanup(),
			ObjList
	end.

nbl_list_files(NblFilename) ->
	StdOut = os:cmd(io_lib:format("~s -t ~s", [?NBL, NblFilename])),
	re:split(StdOut, "\n", [{return, list}]).

nbl_extract_files(NblFilename) ->
	filelib:ensure_dir("tmp/"),
	os:cmd(io_lib:format("~s -o tmp/ ~s", [?NBL, NblFilename])),
	ok.

nbl_cleanup() ->
	{ok, Filenames} = file:list_dir("tmp/"),
	[file:delete(io_lib:format("tmp/~s", [Filename])) || Filename <- Filenames],
	file:del_dir("tmp/"),
	ok.

calc_base_ptr(Filename, [Current|_Tail], Ptr) when Filename =:= Current ->
	Ptr;
calc_base_ptr(Filename, [Current|Tail], Ptr) ->
	FileSize = filelib:file_size(io_lib:format("tmp/~s", [Current])),
	RoundedSize = case FileSize rem 32 of
		0 -> FileSize;
		_ -> 32 * (1 + (FileSize div 32))
	end,
	calc_base_ptr(Filename, Tail, Ptr + RoundedSize).

parse_areaid_list(Data, Ptr) ->
	Bits = Ptr * 8,
	<< _:Bits/bits, AreaCode:16/little-unsigned-integer, NbMaps:16/little-unsigned-integer, MapsListPtr:32/little-unsigned-integer, _/bits >> = Data,
	log("areaid list: area code(~b) nb maps(~b) maps list ptr(~b)", [AreaCode, NbMaps, MapsListPtr]),
	{ok, AreaCode, NbMaps, MapsListPtr}.

parse_mapnumbers_list(Data, NbMaps, Ptr) ->
	IgnoredBits = Ptr * 8,
	MapBits = NbMaps * 12 * 8,
	<< _:IgnoredBits/bits, MapList:MapBits/bits, _/bits >> = Data,
	parse_mapnumbers_list_rec(MapList, NbMaps, []).

parse_mapnumbers_list_rec(_Data, 0, Acc) ->
	lists:reverse(Acc);
parse_mapnumbers_list_rec(Data, NbMaps, Acc) ->
	<< MapID:16/little-unsigned-integer, NbHeaders:16/little-unsigned-integer, ObjListHeadersPtr:32/little-unsigned-integer, 0:32, Rest/bits >> = Data,
	log("mapnumbers list: mapid(~b) nbheaders(~b) object headers ptr(~b)", [MapID, NbHeaders, ObjListHeadersPtr]),
	parse_mapnumbers_list_rec(Rest, NbMaps - 1, [{MapID, NbHeaders, ObjListHeadersPtr}|Acc]).

parse_object_list_headers(BasePtr, Data, NbHeaders, Ptr) ->
	Bits = Ptr * 8,
	<< _:Bits/bits, Rest/bits >> = Data,
	List = parse_object_list_headers_rec(Rest, NbHeaders, []),
	[parse_object_list(BasePtr, Data, NbObjects, ObjListPtr - BasePtr - 16) || {_ObjListNumber, NbObjects, ObjListPtr} <- List].

parse_object_list_headers_rec(_Data, 0, Acc) ->
	lists:reverse(Acc);
parse_object_list_headers_rec(Data, NbHeaders, Acc) ->
	%~ << Log:320/bits, _/bits >> = Data,
	%~ io:format("~p~n", [Log]),
	<< 16#ffffffff:32, UnknownA:144/bits, UnknownB:16/little-unsigned-integer, UnknownC:32/little-unsigned-integer,
		ObjListNumber:16/little-unsigned-integer, 0:32, NbObjects:16/little-unsigned-integer, ObjListPtr:32/little-unsigned-integer, Rest/bits >> = Data,
	log("object list headers: a(~p) b(~p) c(~p) list nb(~b) nb obj(~b) obj list ptr(~b)", [UnknownA, UnknownB, UnknownC, ObjListNumber, NbObjects, ObjListPtr]),
	parse_object_list_headers_rec(Rest, NbHeaders - 1, [{ObjListNumber, NbObjects, ObjListPtr}|Acc]).

parse_object_list(BasePtr, Data, NbObjects, Ptr) ->
	Bits = Ptr * 8,
	<< _:Bits/bits, Rest/bits >> = Data,
	List = parse_object_list_rec(Rest, NbObjects, []),
	[parse_object_args(ObjType, Params, Data, ArgSize, ArgPtr - BasePtr - 16) || {ObjType, Params, ArgSize, ArgPtr} <- List].

parse_object_list_rec(_Data, 0, Acc) ->
	lists:reverse(Acc);
parse_object_list_rec(Data, NbObjects, Acc) ->
	<< 16#ffffffff:32, UnknownA:32/little-unsigned-integer, 16#ffffffff:32, 16#ffff:16, ObjType:16/little-unsigned-integer, 0:32,
		PosX:32/little-float, PosY:32/little-float, PosZ:32/little-float, RotX:32/little-float, RotY:32/little-float, RotZ:32/little-float,
		ArgSize:32/little-unsigned-integer, ArgPtr:32/little-unsigned-integer, Rest/bits >> = Data,
	log("object entry: a(~b) nb(~b) pos[x(~p) y(~p) z(~p)] rot[x(~p) y(~p) z(~p)] argsize(~b) argptr(~b)", [UnknownA, ObjType, PosX, PosY, PosZ, RotX, RotY, RotZ, ArgSize, ArgPtr]),
	parse_object_list_rec(Rest, NbObjects - 1, [{ObjType, {params, {pos, PosX, PosY, PosZ}, {rot, RotX, RotY, RotZ}}, ArgSize, ArgPtr}|Acc]).

parse_object_args(ObjType, Params, Data, Size, Ptr) ->
	BeforeBits = Ptr * 8,
	SizeBits = Size * 8,
	<< _:BeforeBits/bits, Args:SizeBits/bits, _/bits >> = Data,
	parse_object_args(ObjType, Params, Args).

parse_object_args(4, _Params, _Data) ->
	static_model;

%% @todo Many unknowns.
parse_object_args(5, _Params, Data) ->
	<< _:352, TrigEvent:16/little-unsigned-integer, _Unknown:112 >> = Data,
	log("floor_button: trigevent(~p)", [TrigEvent]),
	{floor_button, TrigEvent};

parse_object_args(6, _Params, _Data) ->
	fog;

parse_object_args(9, _Params, _Data) ->
	menu_prompt;

parse_object_args(10, _Params, _Data) ->
	invisible_block;

%% @todo UnknownG or UnknownH is probably the required event.
parse_object_args(12, _Params, Data) ->
	<< Model:16/little-unsigned-integer, UnknownA:16/little-unsigned-integer, UnknownB:32/little-unsigned-integer, UnknownC:16/little-unsigned-integer, Scale:16/little-unsigned-integer,
		UnknownD:16/little-unsigned-integer, 16#ff00:16, UnknownE:16/little-unsigned-integer, UnknownF:16/little-unsigned-integer, UnknownG:16/little-unsigned-integer,
		16#ffff:16, 16#ffffffff:32, 16#ffffffff:32, RawTrigEvent:16/little-unsigned-integer, 16#ffffffff:32, 16#ffffffff:32, 16#ffffffff:32,
		16#ffff:16, UnknownH:16/little-unsigned-integer, 16#ffffffff:32, 16#ffffffff:32, 16#ffffffff:32, 16#ffff:16, UnknownI:16/little-unsigned-integer, 0:16 >> = Data,
	Breakable = case UnknownB of
		0 -> false;
		1 -> true;
		3 -> true; %% @todo This is probably the kind of box that is only targettable (and thus breakable) after the correct event (probably UnknownG) has been sent.
		_ -> true %% @todo No idea. One of them has a value of 0x300 ??
	end,
	TrigEvent = convert_eventid(RawTrigEvent),
	log("box: model(~b) a(~b) breakable(~p) c(~b) scale(~b) d(~b) e(~b) f(~b) g(~b) trigevent(~p) h(~b) i(~b)", [Model, UnknownA, Breakable, UnknownC, Scale, UnknownD, UnknownE, UnknownF, UnknownG, TrigEvent, UnknownH, UnknownI]),
	{box, Model, Breakable, TrigEvent};

parse_object_args(14, {params, {pos, PosX, PosY, PosZ}, _Rot}, Data) ->
	<< _:96, DiffX:32/little-float, DiffY:32/little-float, DiffZ:32/little-float, DestDir:32/little-float, _Unknown:512 >> = Data,
	log("warp: diffpos[x(~p) y(~p) z(~p)] destdir(~p)", [DiffX, DiffY, DiffZ, DestDir]),
	{warp, PosX + DiffX, PosY + DiffY, PosZ + DiffZ, DestDir};

parse_object_args(17, _Params, _Data) ->
	fence;

parse_object_args(18, _Params, _Data) ->
	npc;

parse_object_args(20, _Params, _Data) ->
	door;

parse_object_args(22, _Params, Data) ->
	<< UnknownA:8, 0, KeySet:8, UnknownB:8, 0:16, UnknownC:8, 0, 0:16, UnknownD:16/little-unsigned-integer, RawReqKey1Event:16/little-unsigned-integer,
		RawReqKey2Event:16/little-unsigned-integer, RawReqKey3Event:16/little-unsigned-integer, RawReqKey4Event:16/little-unsigned-integer,
		16#ffffffff:32, 16#ffffffff:32, RawTrigEvent:16/little-unsigned-integer, UnknownE:16/little-unsigned-integer,
		16#ffffffff:32, 16#ffffffff:32, 16#ffffffff:32 >> = Data,
	ReqKeyEvents = [convert_eventid(RawReqKey1Event), convert_eventid(RawReqKey2Event), convert_eventid(RawReqKey3Event), convert_eventid(RawReqKey4Event)],
	TrigEvent = convert_eventid(RawTrigEvent),
	log("key_console: a(~b) keyset(~b) b(~b) c(~b) d(~b) reqkeyevents(~p) trigevent(~p) e(~b)", [UnknownA, KeySet, UnknownB, UnknownC, UnknownD, ReqKeyEvents, TrigEvent, UnknownE]),
	{key_console, KeySet, TrigEvent, ReqKeyEvents};

%% @doc Small spawn.

parse_object_args(23, _Params, Data) ->
	%% @todo return meaningful information
	<< _:704, UnknownA:32/little-unsigned-integer, RawTrigEvent:16/little-unsigned-integer, RawReqEvent:16/little-unsigned-integer, UnknownB:16/little-unsigned-integer, UnknownC:8, SpawnNb:8 >> = Data,
	TrigEvent = convert_eventid(RawTrigEvent),
	ReqEvent = convert_eventid(RawReqEvent),
	log("spawn (x10): a(~b) trigevent(~p) reqevent(~p) b(~b) c(~b) spawnnb(~b)", [UnknownA, TrigEvent, ReqEvent, UnknownB, UnknownC, SpawnNb]),
	{'spawn', 10, TrigEvent, ReqEvent};

%% @doc Big spawn.

parse_object_args(24, _Params, Data) ->
	%% @todo return meaningful information
	<< _:704, UnknownA:32/little-unsigned-integer, RawTrigEvent:16/little-unsigned-integer, RawReqEvent:16/little-unsigned-integer, 16#ffff:16, UnknownB:8, SpawnNb:8 >> = Data,
	TrigEvent = convert_eventid(RawTrigEvent),
	ReqEvent = convert_eventid(RawReqEvent),
	log("spawn (x30): a(~b) trigevent(~p) reqevent(~p) b(~b) spawnnb(~b)", [UnknownA, TrigEvent, ReqEvent, UnknownB, SpawnNb]),
	{'spawn', 30, TrigEvent, ReqEvent};

%% @todo Find out! Big push 3rd zone file.
parse_object_args(25, _Params, _Data) ->
	unknown_object_25;

parse_object_args(26, _Params, _Data) ->
	entrance;

parse_object_args(27, _Params, _Data) ->
	'exit';

%% @todo Find out! Found in Gifts from Beyond+ and that other exchange mission. Also tutorial, all of it.
parse_object_args(28, _Params, _Data) ->
	unknown_object_28;

parse_object_args(31, _Params, Data) ->
	<< KeySet:8, UnknownA:8, UnknownB:8, 1:8, 16#ffff:16, RawTrigEvent:16/little-unsigned-integer, RawReqEvent1:16/little-unsigned-integer, RawReqEvent2:16/little-unsigned-integer,
		RawReqEvent3:16/little-unsigned-integer, 16#ffff:16, 16#ffffffff:32, 16#ffffffff:32 >> = Data,
	TrigEvent = convert_eventid(RawTrigEvent),
	ReqEvents = [convert_eventid(RawReqEvent1), convert_eventid(RawReqEvent2), convert_eventid(RawReqEvent3)],
	log("key: keyset(~b) a(~b) b(~b) trigevent(~p) reqevents(~p)", [KeySet, UnknownA, UnknownB, TrigEvent, ReqEvents]),
	{key, KeySet, TrigEvent, ReqEvents};

%% @todo Find out! Found in Gifts from Beyond+ and that other exchange mission. Also tutorial.
parse_object_args(33, _Params, _Data) ->
	unknown_object_33;

parse_object_args(35, _Params, _Data) ->
	boss;

%% @todo Find out! Big push 2nd zone file.
parse_object_args(39, _Params, _Data) ->
	unknown_object_39;

parse_object_args(40, _Params, _Data) ->
	save_sphere;

%% @todo Seems to be targetable elements found in your room. 3 yellow lines rotating in the otherwise normal map.
parse_object_args(42, _Params, _Data) ->
	unknown_object_42;

parse_object_args(43, _Params, _Data) ->
	shoot_button;

%% @todo Seems to be a zonde turret "trap".

parse_object_args(44, _Params, _Data) ->
	trap;

parse_object_args(45, _Params, _Data) ->
	npc_talk;

%% @todo Might be more than just this counter.
parse_object_args(47, _Params, _Data) ->
	type_counter_npc_talk;

parse_object_args(48, _Params, _Data) ->
	boss_gate;

parse_object_args(49, _Params, _Data) ->
	crystal;

parse_object_args(50, _Params, _Data) ->
	healing_pad;

parse_object_args(51, _Params, _Data) ->
	goggle_target;

parse_object_args(53, _Params, _Data) ->
	label;

%% @todo Found in Scorched Valley, probably is the photon-erasable pods.
parse_object_args(54, _Params, _Data) ->
	unknown_object_54;

parse_object_args(56, _Params, _Data) ->
	chair;

%% @todo Airboard Rally, floaders. Speed boost and healing.
parse_object_args(57, _Params, _Data) ->
	vehicle_boost;

%% @todo Apparently used both for floaders and airboard.
parse_object_args(58, _Params, _Data) ->
	vehicle;

%% @todo Apparently used for the custom posters!
parse_object_args(59, _Params, _Data) ->
	poster;

parse_object_args(60, _Params, _Data) ->
	uni_cube;

parse_object_args(61, _Params, _Data) ->
	ghosts_generator;

parse_object_args(62, _Params, _Data) ->
	pp_cube;

%% @todo Used at the hot springs dressing room.
parse_object_args(63, _Params, _Data) ->
	unknown_object_63;

parse_object_args(64, _Params, _Data) ->
	colored_minimap_section;

parse_object_args(65, _Params, _Data) ->
	room_decoration_slot;

%% @todo Used for the offering box on shitenkaku.
parse_object_args(66, _Params, _Data) ->
	unknown_object_66;

%% @todo Also used for the two ladies: one that gives coins, another that exchanges coins.
parse_object_args(67, _Params, _Data) ->
	casino_bets;

parse_object_args(68, _Params, _Data) ->
	casino_slots;

%% @todo Apparently is in a version of the room that we aren't using yet.
parse_object_args(69, _Params, _Data) ->
	unknown_object_69;

%% @todo Seems to be a megid turret "trap".
parse_object_args(70, _Params, _Data) ->
	trap;

%% @todo Seems to be a ceiling fall-on-you-and-explode "trap". Possibly also poison room. Apparently also fake key.
parse_object_args(71, _Params, _Data) ->
	trap.

convert_eventid(16#ffff) ->
	false;
convert_eventid(RawEventID) ->
	RawEventID.

%% @doc Log message to the console.

log(_Message) ->
	ok.
	%~ io:format("~s~n", [_Message]).

log(Message, Format) ->
	FormattedMessage = io_lib:format(Message, Format),
	log(FormattedMessage).
