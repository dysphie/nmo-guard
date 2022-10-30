#include <sdktools>
#include <sdkhooks>
#include <textparse>
#include <sdkhooks>
#include <vscript_proxy>

#include "nmo-guard/entity-outputs.sp"
#include "nmo-guard/objective-manager.sp"

#pragma semicolon 1
#pragma newdecls required


// TODO: Ignore entities that haven't been seen by the player
// TODO: System to manually add/remove entities from vote menu
// TODO: Reuse script proxy?

#define PLUGIN_VERSION "0.3.6"
#define PLUGIN_DESCRIPTION "Recover lost objective items and handle objective skips gracefully"

bool isLinux;

public Plugin myinfo = 
{
	name = "NMO Guard",
	author = "Dysphie",
	description = PLUGIN_DESCRIPTION,
	version = PLUGIN_VERSION,
	url = "https://github.com/dysphie/nmo-guard"
};

#define PREFIX "\x04[NMO Guard]\x01 "
#define MAX_TARGETNAME_LEN 128
#define MAX_BOUNDARY_ITEMS 10

#define VOTE_FAILED_GENERIC 0
#define VOTE_FAILED_YES_MUST_EXCEED_NO 3
#define VOTE_FAILED_RATE_EXCEEDED 2
#define VOTE_FAILED_DISABLED 5
#define VOTE_FAILED_ON_COOLDOWN 8
#define VOTE_FAILED_SPECTATOR 14

#define MAXPLAYERS_NMRIH 9

#define ISSUE_NONE -1
#define ISSUE_SOFTLOCK 4554

#define VOTE_NOT_VOTING -2
#define VOTE_PENDING -1
#define VOTE_YES 0
#define VOTE_NO 1

#define RECOVER_NOTINBOUNDARY 0
#define RECOVER_OVER_LIMIT 1
#define RECOVER_SUCCESS 2

ConVar quorumRatio;
ConVar specCanVote;

ConVar cvAllowVote;
ConVar cvAllowSkip;

Handle queuedVoteTimer;

int boundarySerial;
Handle saveBoundItemsTimer;

ConVar cvBlip;
ConVar cvFailTimer;
ConVar cvVoteCreateTimer;
ConVar cvMaxRecoverCount;

float failVoteTime = -1.0;
float createVoteTime[MAXPLAYERS_NMRIH+1] = {-1.0, ...};

StringMap recoverHistory;

char recoveringName[256];

int controller;
int choiceCount[2];
int voteCast[MAXPLAYERS_NMRIH+1] = {VOTE_NOT_VOTING, ...};
Handle voteTimer;
int maxVotes;


Handle hCanPickUpObject;
// Profiler prof;

StringMap g_ObjectiveItems;
StringMap entityBackups;
StringMap skipBlacklist;

ArrayList actionsBackups;

char menuItemSound[PLATFORM_MAX_PATH];
char menuExitSound[PLATFORM_MAX_PATH];

enum struct EntityTemplate
{
	int original;
	// bool usesPhysbox;
	float mass;
	char targetname[MAX_TARGETNAME_LEN];
	char classname[64];
	char model[PLATFORM_MAX_PATH];
	float scale;
	int spawnflags;
	int skin;
	float origin[3];
	float angles[3];
	ArrayList outputs;
}

bool CheckCanCallVote(int client)
{
	if (!cvAllowVote.BoolValue)
	{
		SendFailStartVote(client, VOTE_FAILED_DISABLED, 0);
		return false;
	}

	if (IsFakeClient(client))
		return false;

	if (!IsPlayerAlive(client) && !specCanVote.BoolValue)
	{
		SendFailStartVote(client, VOTE_FAILED_SPECTATOR, 0);
		return false;
	}

	if (failVoteTime != -1.0)
	{
		float elapsed = GetGameTime() - failVoteTime;
		if (elapsed < cvFailTimer.FloatValue)
		{
			SendFailStartVote(client, 
				VOTE_FAILED_ON_COOLDOWN,
				RoundToCeil(cvFailTimer.FloatValue - elapsed));
			return false;
		}
	}
	
	if (createVoteTime[client] != -1.0)
	{
		float elapsed = GetGameTime() - createVoteTime[client];
		if (elapsed < cvVoteCreateTimer.FloatValue)
		{
			SendFailStartVote(client, 
				VOTE_FAILED_RATE_EXCEEDED,
				RoundToCeil(cvVoteCreateTimer.FloatValue - elapsed));
			return false;
		}
	}
	

	return true;
}

void SendFailStartVote(int client, int reason, int tryAgainIn)
{
	Handle msg = StartMessageOne("CallVoteFailed", client, USERMSG_RELIABLE);
	BfWrite bf = UserMessageToBfWrite(msg);
	bf.WriteByte(reason); 		
	bf.WriteShort(tryAgainIn);
	EndMessage();
}

enum struct ItemPreview
{
	int cursor;
	int previewEntRef;
	ArrayList previews;
	int serial;

	void Init()
	{
		this.serial = -1;
		this.previewEntRef = -1;
		this.cursor = 0;
	}

	bool Validate(int client)
	{
		if (this.serial != boundarySerial)
		{
			this.Delete();
			PrintToChat(client, PREFIX ... "%t", "Objective Has Changed");
			return false;
		}

		return true;
	}

	void Next(int client)
	{
		if (!this.previews || this.previews.Length <= 0)
		{
			this.DeletePreviewEntity();
			return;
		}

		this.cursor++;
		if (this.cursor >= this.previews.Length)
			this.cursor = 0;

		this.DrawFromList(client);
	}

	void Prev(int client)
	{
		if (!this.previews || this.previews.Length <= 0)
		{
			this.DeletePreviewEntity();
			return;
		}

		this.cursor--;
		if (this.cursor < 0)
			this.cursor = this.previews.Length - 1;

		this.DrawFromList(client);
	}

	void DrawFromList(int client)
	{	
		EntityTemplate data;
		this.previews.GetArray(this.cursor, data, sizeof(data));

		// TODO: should pass EntityTemplate to Draw? why are we saving the full thing again?
		this.Draw(client, data.targetname);
	}

	void Draw(int client, const char[] targetname)
	{
		this.DeletePreviewEntity();
		EntityTemplate data;

		if (!entityBackups.GetArray(targetname, data, sizeof(data)))
			return;
		
		// Turn into dynamic so physics don't spam the console
		// and inventory items cannot be equipped
		int entity = CreateEntityByName("prop_dynamic_override");
		if (entity == -1)
			return;

		DispatchKeyValue(entity, "model", data.model);
		DispatchKeyValueFloat(entity, "modelscale", data.scale);
		DispatchKeyValue(entity, "disablereceiveshadows", "1");
		DispatchKeyValue(entity, "disableshadows", "1");
		SetEntProp(entity, Prop_Data, "m_nSkin", data.skin);

		if (!DispatchSpawn(entity))
			return;
		
		// // Place in front of the player
		float eyeAng[3], eyePos[3], fwd[3], right[3], up[3];
		GetClientEyeAngles(client, eyeAng);
		GetClientEyePosition(client, eyePos);
		GetAngleVectors(eyeAng, fwd, right, up);
		
		float origin[3];
		for (int i; i < sizeof(origin); i++)
			origin[i] = eyePos[i] + (fwd[i] * 30.0) + (right[i] * 0.0) + (up[i] * 0.0);

		TeleportEntity(entity, origin, NULL_VECTOR, NULL_VECTOR);

		//Freeze it in place
		SetVariantString("!activator");
		AcceptEntityInput(entity, "SetParent", client);

		int glowColor;
		g_ObjectiveItems.GetValue(targetname, glowColor);

		GlowEntity(entity, glowColor);
		this.previewEntRef = EntIndexToEntRef(entity);
		SDKHook(entity, SDKHook_SetTransmit, OnPreviewEntTransmit);
		RequestFrame(RotateEntity, this.previewEntRef);
	}

	void DeletePreviewEntity()
	{
		int previewEnt = EntRefToEntIndex(this.previewEntRef);
		if (previewEnt > MaxClients)
			SafeRemoveEntity(previewEnt);
		this.previewEntRef = -1;
	}

	void GetRenderingName(char[] buffer, int maxlen)
	{
		if (!this.previews)
		{
			buffer[0] = '\0';
			return;
			// ThrowError("ItemPreview.GetRenderingName called on struct with no targetnames");
		}

		EntityTemplate data;
		this.previews.GetArray(this.cursor, data, sizeof(data));
		strcopy(buffer, maxlen, data.targetname);
	}

	void Delete()
	{
		this.DeletePreviewEntity();
		delete this.previews;
		this.Init();
	}
}

void RotateEntity(int entref)
{
	if (!IsValidEntity(entref))
		return;

	float curTime = GetGameTime();
	float angles[3];
	
	angles[0] = AngleNormalize(curTime * 20.0 * 1.0);
	angles[1] = AngleNormalize(curTime * 20.0 * 5.0);
	angles[2] = AngleNormalize(curTime * 20.0 * 1.0);
	TeleportEntity(entref, NULL_VECTOR, angles, NULL_VECTOR);

	RequestFrame(RotateEntity, entref);
}

ConVar g_cvSizeLimit, g_cvMassLimit;
char g_MapName[PLATFORM_MAX_PATH];
bool g_Lateloaded;

ItemPreview itemPreview[MAXPLAYERS_NMRIH+1];


Action OnPreviewEntTransmit(int entity, int client)
{
	if (EntIndexToEntRef(entity) != itemPreview[client].previewEntRef)
		return Plugin_Handled;

	return Plugin_Continue;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_Lateloaded = late;
	return APLRes_Success;
}

public void OnMapStart()
{
	if (menuExitSound[0])
		PrecacheSound(menuExitSound);
	if (menuItemSound[0])
		PrecacheSound(menuItemSound);

	int controllerIdx = FindEntityByClassname(-1, "vote_controller");
	if (controllerIdx != -1) {
		controller = EntIndexToEntRef(controllerIdx);
	}

	GetCurrentMap(g_MapName, sizeof(g_MapName));

	// FIXME: Re enable, its crashing
	if (g_Lateloaded)
		objMgr.GetObjectiveChain(objectiveChain);
}

public void OnClientPutInServer(int client)
{
	itemPreview[client].Init();
}

public void OnClientDisconnect(int client)
{
	itemPreview[client].Delete();

	int choice = voteCast[client];
	if (choice != VOTE_NOT_VOTING)
	{
		maxVotes--;
		if (choice > VOTE_PENDING)
			choiceCount[choice]--;

		voteCast[client] = VOTE_NOT_VOTING;
		CheckForEarlyVoteClose();
	}
}

public void OnPluginStart()
{
	cvFailTimer = FindConVar("sv_vote_failure_timer");
	cvVoteCreateTimer = FindConVar("sv_vote_creation_timer");
	cvBlip = CreateConVar("sm_nmoguard_clone_show_blip", "1");
	cvMaxRecoverCount = CreateConVar("sm_nmoguard_clone_max_count", "2");

	cvAllowVote = CreateConVar("sm_nmoguard_allow_item_vote", "1");
	cvAllowSkip = CreateConVar("sm_nmoguard_allow_obj_skip", "0");

	CreateConVar("nmo_guard_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION,
    	FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_DONTRECORD);

	// Handle panel sounds
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/core.cfg");
	SMCParser parser = new SMCParser();
	parser.OnKeyValue = OnKeyValue;
	parser.ParseFile(path);
	delete parser;

	recoverHistory = new StringMap();
	objectiveChain = new ArrayList();
	skipBlacklist = new StringMap();
	actionsBackups = new ArrayList();

	// prof = new Profiler();

	LoadTranslations("nmoguard.phrases");
	LoadGamedata();
	LoadSkipBlacklist();

	g_cvMassLimit = FindConVar("sv_pickup_masslimit");
	g_cvSizeLimit = FindConVar("sv_pickup_sizelimit");

	g_ObjectiveItems = new StringMap();
	entityBackups = new StringMap();

	RegConsoleCmd("sm_sl", OnCmdSoftlock);
	RegConsoleCmd("sm_softlock", OnCmdSoftlock);
	RegConsoleCmd("sm_bug", OnCmdSoftlock);
	
	HookEntityOutput("nmrih_objective_boundary", "OnObjectiveBegin", OnBoundaryBegin);

	quorumRatio = FindConVar("sv_vote_quorum_ratio");
	specCanVote = FindConVar("sv_vote_allow_spectators");

	HookEvent("objective_complete", OnObjectiveComplete, EventHookMode_Pre);
	HookUserMessage(GetUserMessageId("ObjectiveNotify"), OnObjectiveNotify, true);
	RegAdminCmd("sm_objskip", OnCmdNext, ADMFLAG_CHEATS);
	RegAdminCmd("sm_objskip_refresh_blacklist", OnCmdRefreshSkipBlacklist, ADMFLAG_CHEATS);

	AddCommandListener(Vote, "vote");

	for (int i = 1; i <= MaxClients; i++)
		voteCast[i] = VOTE_NOT_VOTING;

	if (g_Lateloaded)
	{
		int e = -1;
		while ((e = FindEntityByClassname(e, "nmrih_objective_boundary")) != -1)
			OnBoundarySpawned(e);
		
		e = -1;
		while ((e = FindEntityByClassname(e, "prop_physic*")) != -1)
			if (IsCarriableObjectiveItem(e))
				SaveEntity(e);

		e = -1;
		while ((e = FindEntityByClassname(e, "tool_*")) != -1)
			if (IsCarriableObjectiveItem(e))
				SaveEntity(e);
	}

	HookEvent("nmrih_reset_map", OnMapReset, EventHookMode_Pre);
	HookEvent("objective_complete", OnObjectiveComplete);

	// TODO: This is kinda bad, a player could potentially stop living
	// without these events ever firing. We should SDKHook_Think instead
	HookEvent("player_extracted", OnPlayerExtracted);
	HookEvent("player_death", OnPlayerDeath, EventHookMode_Pre);

	AutoExecConfig();
}

public void OnBoundaryBegin(const char[] output, int boundary, int activator, float delay)
{
	boundarySerial++;
	EnsureNoActiveVote();

	delete saveBoundItemsTimer;
	saveBoundItemsTimer = CreateTimer(1.0, SaveBoundaryItems, 
		EntIndexToEntRef(boundary), TIMER_FLAG_NO_MAPCHANGE);
}

void LoadSkipBlacklist()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/nmo-guard.cfg");

	KeyValues kv = new KeyValues("nmoguard");

	if (!kv.ImportFromFile(path))
	{
		SetFailState("Missing file \"%s\"", path);
	}

	if (kv.JumpToKey("skip_blacklist"))
	{
		if (kv.GotoFirstSubKey(false))
		{
			do
			{
				char buffer[PLATFORM_MAX_PATH], objName[256];
				kv.GetSectionName(buffer, sizeof(buffer));
				kv.GetString(NULL_STRING, objName, sizeof(objName));

				Format(buffer, sizeof(buffer), "%s %s", buffer, objName);
				skipBlacklist.SetValue(buffer, true);
			}
			while (kv.GotoNextKey(false));	

			kv.GoBack();
		}

		kv.GoBack();
	}

	delete kv;
}

public void OnPlayerExtracted(Event event, const char[] name, bool dontBroadcast)
{
	int client = event.GetInt("player_id");
	if (0 < client <= MaxClients && IsClientInGame(client))
		itemPreview[client].Delete();
}

public void OnPlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client)
		itemPreview[client].Delete();
}

void EnsureNoActiveVote()
{
	delete queuedVoteTimer;

	if (GetActiveVoteIssue() == ISSUE_SOFTLOCK)
	{
		SendSoftlockVoteFail(VOTE_FAILED_GENERIC);
		SoftlockVoteReset();
	}
}

SMCResult OnKeyValue(SMCParser smc, const char[] key, const char[] value, bool key_quotes, bool value_quotes)
{
	if (!strcmp(key, "MenuItemSound"))
		strcopy(menuItemSound, sizeof(menuItemSound), value);
	else if (!strcmp(key, "MenuExitSound"))
		strcopy(menuExitSound, sizeof(menuExitSound), value);

	return SMCParse_Continue;
}

bool IsCarriableObjectiveItem(int entity)
{
	static char targetname[MAX_TARGETNAME_LEN];
	if (!GetEntityTargetname(entity, targetname, sizeof(targetname)))
	{
		return false;
	}
	else if (!CanBePickedUp(entity))
	{
		return false;
	}
	else
	{
		any val;
		return g_ObjectiveItems.GetValue(targetname, val);
	}
}

void LoadGamedata()
{
	GameData gamedata = new GameData("nmo-guard.games");
	if(!gamedata)
		SetFailState("Failed to load gamedata");

	isLinux = GetOffsetOrFail(gamedata, "IsLinux") == 1;

	EntityOutputs_LoadGameData(gamedata);
	ObjectiveManager_LoadGameData(gamedata);

	StartPrepSDKCall(SDKCall_Static);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CBasePlayer::CanPickupObject");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Float, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_Plain);
	hCanPickUpObject = EndPrepSDKCall();
	if (!hCanPickUpObject)
		SetFailState("Failed to resolve address of CBasePlayer::CanPickupObject");


	delete gamedata;
}

public void OnBoundarySpawned(int boundary)
{
	// Ignore dynamically spawned boundaries as it's causing issues with
	// plugins that use them to glow custom props (e.g. backpacks)
	// TODO: Special cases for each?
	int hammerid = GetEntProp(boundary, Prop_Data, "m_iHammerID");
	if (!hammerid)
		return;

	int colors[MAX_BOUNDARY_ITEMS];
	char targetnames[MAX_BOUNDARY_ITEMS][MAX_TARGETNAME_LEN];
	GetBoundaryItemData(boundary, targetnames, colors);

	for (int i; i < sizeof(targetnames); i++)
	{
		if (targetnames[i][0])
			g_ObjectiveItems.SetValue(targetnames[i], colors[i]);
	}

	CreateTimer(0.1, SaveBoundaryItems, EntIndexToEntRef(boundary), TIMER_FLAG_NO_MAPCHANGE);
}

Action SaveBoundaryItems(Handle timer, int boundaryRef)
{
	saveBoundItemsTimer = null;

	int boundary = EntRefToEntIndex(boundaryRef);
	if (boundary == -1)
		return Plugin_Stop;

	int colors[MAX_BOUNDARY_ITEMS];
	char targetnames[MAX_BOUNDARY_ITEMS][MAX_TARGETNAME_LEN];
	GetBoundaryItemData(boundary, targetnames, colors);

	char targetname[MAX_TARGETNAME_LEN];

	int i = -1;
	while ((i = FindEntityByClassname(i, "prop_physic*")) != -1)
	{
		if (!GetEntityTargetname(i, targetname, sizeof(targetname)))
			continue;

		for (int j; j < sizeof(targetnames); j++)
		{
			if (targetnames[j][0] && StrEqual(targetname, targetnames[j]) && CanBePickedUp(i))
			{
				SaveEntity(i);
				break;
			}
		}
	}

	i = -1;
	while ((i = FindEntityByClassname(i, "tool_*")) != -1)
	{
		if (!GetEntityTargetname(i, targetname, sizeof(targetname)))
			continue;

		for (int j; j < sizeof(targetnames); j++)
		{
			if (targetnames[j][0] && StrEqual(targetname, targetnames[j]) && CanBePickedUp(i))
			{
				SaveEntity(i);
				break;
			}
		}
	}

	return Plugin_Stop;
}

public void OnMapEnd()
{
	SoftlockVoteReset();
	FlushEntityBackups();
	g_ObjectiveItems.Clear();
}

void FlushEntityBackups()
{
	entityBackups.Clear();

	for (int i; i < actionsBackups.Length; i++)
	{
		ArrayList actions = actionsBackups.Get(i);
		delete actions;
	}

	actionsBackups.Clear();
}

void GetRecoverableItems(ArrayList arr)
{
	int boundary = -1;
	while ((boundary = FindEntityByClassname(boundary, "nmrih_objective_boundary")) != -1)
	{
		if (GetEntProp(boundary, Prop_Send, "m_bActive"))
		{
			int colors[MAX_BOUNDARY_ITEMS];
			char names[MAX_BOUNDARY_ITEMS][MAX_TARGETNAME_LEN];
			GetBoundaryItemData(boundary, names, colors);

			EntityTemplate data;
			
			for (int i; i < sizeof(names); i++)
			{
				if (!names[i] || !entityBackups.GetArray(names[i], data, sizeof(data)))
					continue;

				// TODO: Commented out because entities move after spawning
				// Figure out a better way of filtering out entities that haven't been interacted with

				// Don't add if original still exists at first seen position
				// Skip this check if we lateloaded, we could have loaded when the item is already softlocked
				// if (!g_Lateloaded && IsValidEntity(data.original))
				// {
				// 	float pos[3];
				// 	GetEntPropVector(data.original, Prop_Send, "m_vecOrigin", pos);

				// 	// PrintToServer("%f %f %f == %f %f %f", pos[0], pos[1], pos[2], data.origin[0], data.origin[1], data.origin[2]);
				// 	if (pos[0] == data.origin[0] && pos[1] == data.origin[1] && pos[2] == data.origin[2])
				// 		continue;
				// }

				arr.PushArray(data);
			}
		}
	}
}

// public Action OnCmdCarry(int client, int args)
// {
// 	int target = GetCmdArgInt(1);
// 	if (!IsValidEntity(target))
// 	{
// 		ReplyToCommand(client, "Invalid entity %d", target);
// 		return Plugin_Handled;
// 	}

// 	ReplyToCommand(client, "%d", IsCarriableObjectiveItem(target));
// 	return Plugin_Handled;
// }

// public Action OnCmdDumpItems(int client, int args)
// {
// 	StringMapSnapshot snap = g_ObjectiveItems.Snapshot();
// 	for (int i; i < snap.Length; i++)
// 	{
// 		char targetname[MAX_TARGETNAME_LEN];
// 		snap.GetKey(i, targetname, sizeof(targetname));
// 		ReplyToCommand(client, "dump_items: %s", targetname);
// 	}
// 	delete snap;
// 	return Plugin_Handled;
// }

// public Action OnCmdDumpBackups(int client, int args)
// {
// 	StringMapSnapshot snap = entityBackups.Snapshot();
// 	for (int i; i < snap.Length; i++)
// 	{
// 		char targetname[MAX_TARGETNAME_LEN];
// 		snap.GetKey(i, targetname, sizeof(targetname));
// 		ReplyToCommand(client, "backup: %s", targetname);
// 	}
// 	delete snap;
// 	return Plugin_Handled;
// }

Action OnCmdSoftlock(int client, int args)
{
	if (!client || !CheckCanCallVote(client))
		return Plugin_Handled;

	ArrayList recoverable = new ArrayList(sizeof(EntityTemplate));
	GetRecoverableItems(recoverable);

	if (recoverable.Length > 0)
	{
		itemPreview[client].Delete();
		itemPreview[client].serial = boundarySerial;
		itemPreview[client].previews = recoverable;
		itemPreview[client].Next(client);
		ShowPreviewControls(client);
	}
	else
	{
		ReplyToCommand(client, PREFIX ... "%t", "No Items");
		delete recoverable;
	}
	
	return Plugin_Handled;
}

enum
{
	SOFTMENU_NEXT = 1,
	SOFTMENU_PREV,
	SOFTMENU_RECOVER,
	SOFTMENU_EXIT = 10
}

void ShowPreviewControls(int client)
{
	int numItems = itemPreview[client].previews.Length;

	Panel p = new Panel();

	char buffer[1024];
	FormatEx(buffer, sizeof(buffer), "%T", "Softlock Panel Title", client);
	p.DrawText(buffer);

	FormatEx(buffer, sizeof(buffer), "%T", "Softlock Panel Next", client);
	p.DrawItem(buffer, numItems > 1 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	FormatEx(buffer, sizeof(buffer), "%T", "Softlock Panel Prev", client);
	p.DrawItem(buffer, numItems > 1 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	p.DrawText(" ");

	FormatEx(buffer, sizeof(buffer), "%T", "Softlock Panel Recover Hint", client);
	p.DrawText(buffer);

	FormatEx(buffer, sizeof(buffer), "%T", "Softlock Panel Recover", client);
	p.DrawItem(buffer);
	p.DrawText(" ");

	p.CurrentKey = 10;
	p.DrawItem("Exit");
	p.Send(client, OnPreviewControls, 0);
	delete p;	
}

public int OnPreviewControls(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			switch (param2)
			{
				case SOFTMENU_NEXT:			
				{
					EmitSoundToClient(param1, menuItemSound);
					if (itemPreview[param1].Validate(param1))
					{
						itemPreview[param1].Next(param1);
						ShowPreviewControls(param1);
					}
				}
				case SOFTMENU_PREV:			
				{
					EmitSoundToClient(param1, menuItemSound);
					if (itemPreview[param1].Validate(param1))
					{
						itemPreview[param1].Prev(param1);
						ShowPreviewControls(param1);
					}
				}
				case SOFTMENU_RECOVER:			
				{
					EmitSoundToClient(param1, menuItemSound);

					if (!itemPreview[param1].Validate(param1))
					{
						return 0;
					}

					if (!CheckCanCallVote(param1))
					{
						itemPreview[param1].Delete();
						return 0;
					}

					char targetname[MAX_TARGETNAME_LEN];
					itemPreview[param1].GetRenderingName(targetname, sizeof(targetname));
					if (!targetname[0] || !CanRecoverTargetname(targetname))
					{
						PrintToChat(param1, PREFIX ... "%t", "Hit Recovery Limit");
						itemPreview[param1].Delete();
						return 0;
					}
					
					strcopy(recoveringName, sizeof(recoveringName), targetname);
					// Wait a second so the callvote panel doesn't overlap with this one

					delete queuedVoteTimer;
					queuedVoteTimer = CreateTimer(1.0, TimerCreateSoftlockVote, 
						GetClientUserId(param1), TIMER_FLAG_NO_MAPCHANGE);
	
					itemPreview[param1].Delete();
				}
				case SOFTMENU_EXIT:
				{
					itemPreview[param1].Delete();
					EmitSoundToClient(param1, menuExitSound);
				}
			}
		}

		case MenuAction_Cancel:
		{
			itemPreview[param1].Delete();
		}
	}

	return 0;
}

public Action TimerCreateSoftlockVote(Handle timer, int userid)
{
	queuedVoteTimer = null;

	int client = GetClientOfUserId(userid);
	if (!client)
		recoveringName[0] = '\0';
	else
		CreateSoftlockVote(client);
	return Plugin_Stop;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	#if !defined _sdkhooks_included
		#error "Missing 'sdkhooks' include"
	#endif

	if (!IsValidEdict(entity))
		return;

	if (StrEqual(classname, "nmrih_objective_boundary"))
		SDKHook(entity, SDKHook_SpawnPost, OnBoundarySpawned);

	else if (!StrContains(classname, "prop_physics") || !StrContains(classname, "tool_"))
		SDKHook(entity, SDKHook_SpawnPost, OnPropSpawned);
}

public void OnPropSpawned(int entity)
{
	if (IsCarriableObjectiveItem(entity))
		RequestFrame(SaveEntityByReference, EntIndexToEntRef(entity));
}

void SaveEntityByReference(int entref)
{
	int entity = EntRefToEntIndex(entref);
	if (entity != -1)
		SaveEntity(entity);
}

void GetBoundaryItemData(int boundary, char names[MAX_BOUNDARY_ITEMS][MAX_TARGETNAME_LEN], int colors[MAX_BOUNDARY_ITEMS]) 
{
	// This is ugly but faster than iterating
	GetEntPropString(boundary, Prop_Data, "m_szGlowEntityNames[0]", names[0], MAX_TARGETNAME_LEN);
	GetEntPropString(boundary, Prop_Data, "m_szGlowEntityNames[1]", names[1], MAX_TARGETNAME_LEN);
	GetEntPropString(boundary, Prop_Data, "m_szGlowEntityNames[2]", names[2], MAX_TARGETNAME_LEN);
	GetEntPropString(boundary, Prop_Data, "m_szGlowEntityNames[3]", names[3], MAX_TARGETNAME_LEN);
	GetEntPropString(boundary, Prop_Data, "m_szGlowEntityNames[4]", names[4], MAX_TARGETNAME_LEN);
	GetEntPropString(boundary, Prop_Data, "m_szGlowEntityNames[5]", names[5], MAX_TARGETNAME_LEN);
	GetEntPropString(boundary, Prop_Data, "m_szGlowEntityNames[6]", names[6], MAX_TARGETNAME_LEN);
	GetEntPropString(boundary, Prop_Data, "m_szGlowEntityNames[7]", names[7], MAX_TARGETNAME_LEN);
	GetEntPropString(boundary, Prop_Data, "m_szGlowEntityNames[8]", names[8], MAX_TARGETNAME_LEN);
	GetEntPropString(boundary, Prop_Data, "m_szGlowEntityNames[9]", names[9], MAX_TARGETNAME_LEN);
	colors[0] = GetEntProp(boundary, Prop_Data, "m_GlowEntityColors[0]");
	colors[1] = GetEntProp(boundary, Prop_Data, "m_GlowEntityColors[1]");
	colors[2] = GetEntProp(boundary, Prop_Data, "m_GlowEntityColors[2]");
	colors[3] = GetEntProp(boundary, Prop_Data, "m_GlowEntityColors[3]");
	colors[4] = GetEntProp(boundary, Prop_Data, "m_GlowEntityColors[4]");
	colors[5] = GetEntProp(boundary, Prop_Data, "m_GlowEntityColors[5]");
	colors[6] = GetEntProp(boundary, Prop_Data, "m_GlowEntityColors[6]");
	colors[7] = GetEntProp(boundary, Prop_Data, "m_GlowEntityColors[7]");
	colors[8] = GetEntProp(boundary, Prop_Data, "m_GlowEntityColors[8]");
	colors[9] = GetEntProp(boundary, Prop_Data, "m_GlowEntityColors[9]");
}

void SaveEntity(int entity)
{
	EntityTemplate data;
	if (!GetEntityTargetname(entity, data.targetname, sizeof(data.targetname)))
		return;

	// Refuse to save twice
	if (entityBackups.GetArray(data.targetname, data, sizeof(data)))
		return;

	GetEntityClassname(entity, data.classname, sizeof(data.classname));

	// Some physics props need a bit of help spawning
	if (StrEqual(data.classname, "prop_physics"))
		StrCat(data.classname, sizeof(data.classname), "_override");

	data.spawnflags = GetEntProp(entity, Prop_Data, "m_spawnflags");
	data.scale = GetEntPropFloat(entity, Prop_Send, "m_flModelScale");
	data.original = EntIndexToEntRef(entity);
	data.skin = GetEntProp(entity, Prop_Data, "m_nSkin");

	data.mass = RunEntVScriptFloat(entity, "GetMass()");


	GetEntPropVector(entity, Prop_Send, "m_vecOrigin", data.origin);
	GetEntPropVector(entity, Prop_Data, "m_angRotation", data.angles);
	GetEntPropString(entity, Prop_Data, "m_ModelName", data.model, sizeof(data.model));

	// This crashes Linux currently, disable until we figure it out
	if (!isLinux)
	{
		data.outputs = GetEntityOutputs(entity);
		if (data.outputs)
		{
			actionsBackups.Push(data.outputs);
		}
	}

	entityBackups.SetArray(data.targetname, data, sizeof(data));
}

int GetEntityTargetname(int entity, char[] buffer, int maxlen)
{
	return GetEntPropString(entity, Prop_Data, "m_iName", buffer, maxlen);
}

bool CanBePickedUp(int entity)
{
	return SDKCall(hCanPickUpObject, entity, g_cvMassLimit.FloatValue, g_cvSizeLimit.FloatValue);
}

bool RestoreEntity(const char[] targetname)
{
	EntityTemplate data;
	if (!entityBackups.GetArray(targetname, data, sizeof(data)))
		return false;

	// Spawn dummy 
	int dummy = CreateEntityByName(data.classname);
	if (dummy == -1)
		return false;

	DispatchKeyValue(dummy, "model", data.model);
	DispatchKeyValueFloat(dummy, "modelscale", data.scale);
	DispatchKeyValueVector(dummy, "origin", data.origin);
	DispatchKeyValueVector(dummy, "angles", data.angles);
	SetEntProp(dummy, Prop_Data, "m_spawnflags", data.spawnflags);
	SetEntProp(dummy, Prop_Data, "m_nSkin", data.skin);

	// Restore outputs
	if (!isLinux && data.outputs) {
		WriteEntityOutputs(data.outputs, dummy);
	}

	if (!DispatchSpawn(dummy))
		return false;

	char massCode[30];
	FormatEx(massCode, sizeof(massCode), "SetMass(%f)", data.mass);
	RunEntVScript(dummy, massCode);

	int glowColor;
	g_ObjectiveItems.GetValue(data.targetname, glowColor);
	DispatchKeyValue(dummy, "targetname", data.targetname);
	
	// Why do we call this again? Shouldn't the targetname make it glow already?
	GlowEntity(dummy, glowColor);

	int recoverCount;
	recoverHistory.GetValue(data.targetname, recoverCount);
	recoverHistory.SetValue(data.targetname, ++recoverCount);

	ActivateEntity(dummy);

	// CreateTimer(3.0, ReApplyGlow, EntIndexToEntRef(dummy), TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	return true;
}

// Terrible hack: Clients sometimes refuse to glow the clone if it wasn't in
// their field of view when the original glow was applied
// public Action ReApplyGlow(Handle timer, int dummyRef)
// {
// 	if (!IsValidEntity(dummyRef))
// 		return Plugin_Stop;

// 	int glow = GetEntProp(dummyRef, Prop_Data, "m_clrGlowColor");
// 	GlowEntity(dummyRef, glow);
// 	return Plugin_Continue;
// }

Action OnMapReset(Event event, const char[] name, bool dontBroadcast)
{
	FlushEntityBackups();
	recoverHistory.Clear();

	if (!objMgr)
		return Plugin_Continue;
		// ThrowError("Called objMgr.objectiveChain but objMgr is null");
	
	objectiveChain.Clear();
	objMgr.GetObjectiveChain(objectiveChain);

	return Plugin_Continue;
}

void GlowEntity(int entity, int color)
{
	DispatchKeyValue(entity, "glowable", "1"); 
	
	if (cvBlip.BoolValue)
		DispatchKeyValue(entity, "glowblip", "1");

	if (HasEntProp(entity, Prop_Data, "m_clrGlowColor"))
		SetEntProp(entity, Prop_Data, "m_clrGlowColor", color);

	DispatchKeyValue(entity, "glowdistance", "9999");
	AcceptEntityInput(entity, "enableglow");
}

public void OnPluginEnd()
{
	EnsureNoActiveVote();

	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i))
			itemPreview[i].Delete();
}

stock float fmodf(float x, float y) 
{ 
	return x - y * RoundToFloor(x/y); 
}  

stock float AngleNormalize(float ang)
{
	ang = fmodf( ang, 360.0 ); 
	
	if ( ang > 180.0 ) 
		ang -= 360.0;
	
	if ( ang < -180.0 ) 
		ang += 360.0;
	
	return ang;
}

void SafeRemoveEntity(int entity)
{
	if (entity < 0)
		return;
	RemoveEntity(entity);
}

public void OnClientConnected(int client)
{
	voteCast[client] = VOTE_NOT_VOTING;
	createVoteTime[client] = -1.0;
}

void EndVote()
{
	int yes = choiceCount[VOTE_YES];
	int no = choiceCount[VOTE_NO];

	if (yes + no >= maxVotes * quorumRatio.FloatValue && yes > no)
	{
		if (!CanRecoverTargetname(recoveringName))
		{
			failVoteTime = GetGameTime();
			SendSoftlockVoteFail(VOTE_FAILED_GENERIC);
		}
		else
		{
			SendSoftlockVoteSuccess();
			RestoreEntity(recoveringName);
		}
	}
	else
	{
		failVoteTime = GetGameTime();
		SendSoftlockVoteFail();
	}

	SoftlockVoteReset();
}

// void PrintToVoters(const char[] message, any ...) 
// {
// 	char buffer[1024];

// 	for (int i = 1; i <= MaxClients; i++)
// 	{
// 		if (voteCast[i] != VOTE_NOT_VOTING && IsClientInGame(i))
// 		{
// 			SetGlobalTransTarget(i);
// 			VFormat(buffer, sizeof(buffer), message, 2);
// 			PrintToChat(i, buffer);
// 		}
// 	}
// }

bool CanRecoverTargetname(const char[] targetname)
{
	int recoverCount;
	recoverHistory.GetValue(targetname, recoverCount);
	if (recoverCount >= cvMaxRecoverCount.IntValue)
		return false;

	ArrayList recoverable = new ArrayList(sizeof(EntityTemplate));
	GetRecoverableItems(recoverable);

	bool result = false;
	EntityTemplate data;

	for (int i; i < recoverable.Length; i++)
	{
		recoverable.GetArray(i, data);
		if (StrEqual(data.targetname, targetname))
			result = true;		
	}

	delete recoverable;
	return result;
}

void SoftlockVoteReset()
{
	delete voteTimer;

	choiceCount[VOTE_YES] = 0;
	choiceCount[VOTE_NO] = 0;
	maxVotes = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && voteCast[i] == VOTE_PENDING)
			itemPreview[i].Delete();
		voteCast[i] = VOTE_NOT_VOTING;
	}

	SetActiveVoteIssue(ISSUE_NONE);
}

public Action OnCmdCreateSoftlockVote(int client, int args)
{
	if (GetActiveVoteIssue() != ISSUE_NONE)
		ReplyToCommand(client, PREFIX ... "Vote already in progress");
	else
		CreateSoftlockVote(client);

	return Plugin_Handled;
}

void SetActiveVoteIssue(int issue)
{
	if (IsValidEntity(controller))
		SetEntProp(controller, Prop_Send, "m_iActiveIssueIndex", issue);
}

int GetActiveVoteIssue()
{
	if (IsValidEntity(controller))
		return GetEntProp(controller, Prop_Send, "m_iActiveIssueIndex");
	return -1;
}

void SendSoftlockVoteSuccess()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (voteCast[i] == VOTE_NOT_VOTING || !IsClientInGame(i))
			continue;
		
		char text[255];
		FormatEx(text, sizeof(text), "%T\n\n\n\n\n\n\n\n\n", "Softlock Vote Success", i);

		Handle msg = StartMessageOne("VotePass", i, USERMSG_RELIABLE);
		BfWrite bf = UserMessageToBfWrite(msg);						
		bf.WriteByte(0); 
		bf.WriteString("#SDK_Chat_All"); 
		bf.WriteString(text);
		EndMessage();
	}
}

void SendSoftlockVoteFail(int reason = VOTE_FAILED_YES_MUST_EXCEED_NO)
{
	int maxTargets;
	int[] targets = new int[MaxClients];
	for (int i = 1; i <= MaxClients; i++)
		if (voteCast[i] != VOTE_NOT_VOTING && IsClientInGame(i))
			targets[maxTargets++] = i;

	Handle msg = StartMessage("VoteFailed", targets, maxTargets, USERMSG_RELIABLE);
	BfWrite bf = UserMessageToBfWrite(msg);		
	bf.WriteByte(0);  								
	bf.WriteByte(reason);
	EndMessage();	
}

public Action Vote(int client, const char[] command, int argc)
{
	if (GetActiveVoteIssue() != ISSUE_SOFTLOCK)
		return Plugin_Continue;

	if (voteCast[client] != VOTE_PENDING)
		return Plugin_Handled;

	char arg[9];
	GetCmdArg(1, arg, sizeof(arg));
	int choice = !StrEqual(arg, "option1", false);

	choiceCount[choice]++;
	voteCast[client] = choice;

	itemPreview[client].Delete();

	CheckForEarlyVoteClose();

	Event event = CreateEvent("vote_cast");
	event.SetInt("entityid", client);
	event.SetInt("team", 0);
	event.SetInt("vote_option", choice);
	event.Fire();

	SendPanelUpdate();
	return Plugin_Handled;
}

void CreateSoftlockVote(int initiator)
{
	createVoteTime[initiator] = GetGameTime();

	SetActiveVoteIssue(ISSUE_SOFTLOCK);
	char text[255];

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !CanClientCastVote(i))
		{
			voteCast[i] = VOTE_NOT_VOTING;
			continue;
		}

		maxVotes++;
		voteCast[i] = VOTE_PENDING;

		Handle msg = StartMessageOne("VoteStart", i, USERMSG_RELIABLE);
		BfWrite bf = UserMessageToBfWrite(msg);
		bf.WriteByte(0); 		
		bf.WriteByte(initiator); 				
		bf.WriteString("#SDK_Chat_All"); 
		FormatEx(text, sizeof(text), "%T\n\n\n\n\n\n\n\n\n", "Softlock Vote Description", i);
		bf.WriteString(text);
		bf.WriteBool(true);
		EndMessage();

		if (i != initiator)
			itemPreview[i].Draw(i, recoveringName);
	}

	if (initiator > 0)
	{
		FakeClientCommand(initiator, "vote option1");
	}
	else
	{
		SendPanelUpdate();
	}

	voteTimer = CreateTimer(15.0, ExpireVoteAndDeletePreviews, _, TIMER_FLAG_NO_MAPCHANGE);
}

void SendPanelUpdate()
{
	Event event = CreateEvent("vote_changed");
	event.SetInt("potentialVotes", 2);
	event.SetInt( "vote_option1", choiceCount[VOTE_YES]);
	event.SetInt( "vote_option2", choiceCount[VOTE_NO]);
	event.Fire();
}

void CheckForEarlyVoteClose()
{
	if (choiceCount[VOTE_YES] + choiceCount[VOTE_NO] >= maxVotes)
		CreateTimer(0.2, TimerEndVote, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action TimerEndVote(Handle timer)
{
	EndVote();
	return Plugin_Continue;
}

bool CanClientCastVote(int client)
{
	return !IsFakeClient(client) && (IsPlayerAlive(client) || specCanVote.BoolValue);
}

Action ExpireVoteAndDeletePreviews(Handle timer)
{
	voteTimer = null;
	EndVote();
	return Plugin_Continue;
}

Action OnObjectiveNotify(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init)
{
	return ignoreObjHooks ? Plugin_Handled : Plugin_Continue; 
}

public void ObjectiveManager_StartNextObjective(Address addr)
{ 
	SDKCall(startNextObjectiveFn, addr);
}

public void ObjectiveBoundary_Finish(Address addr)
{
	SDKCall(boundaryFinishFn, addr);
}

Action OnObjectiveComplete(Event event, const char[] name, bool silent)
{
	if (!cvAllowSkip.BoolValue || ignoreObjHooks)
		return Plugin_Continue;

	char buffer[PLATFORM_MAX_PATH], objName[256];
	GetCurrentMap(buffer, sizeof(buffer));
	event.GetString("name", objName, sizeof(objName));
	Format(buffer, sizeof(buffer), "%s %s", buffer, objName);

	any val;
	if (skipBlacklist.GetValue(buffer, val))
	{
		return Plugin_Continue;
	}

	Objective pCurObj = objMgr.currentObjective;
	if (!pCurObj)
		return Plugin_Continue;

	int doneObjIdx = objectiveChain.FindValue(event.GetInt("id"));
	if (doneObjIdx == -1)
	{
		PrintToServer(PREFIX ... "Completed objective not in objective chain. Ignoring..");
		return Plugin_Continue;
	}

	int curObjIdx = objectiveChain.FindValue(pCurObj.ID);
	if (curObjIdx == -1)
	{
		PrintToServer(PREFIX ... "Current objective not in objective chain. Ignoring..");
		return Plugin_Continue;
	}

	int numSkipped = doneObjIdx - curObjIdx;	

	if (numSkipped > 0)
	{
		PrintToChatAll(PREFIX ... "%t", "Objective Skip");
		ignoreObjHooks = true;
		do 
		{
			objMgr.CompleteCurrentObjective();
			numSkipped--;
		} 
		while (numSkipped);
		ignoreObjHooks = false;
	}

	return Plugin_Continue;
}

Action OnCmdNext(int client, int args)
{
	if (!objMgr || GameRules_GetProp("_roundState") != 3)
	{
		ReplyToCommand(client, PREFIX ... "No running objective detected");
	}
	else
	{
		objMgr.CompleteCurrentObjective();	
	}
	return Plugin_Handled;
}

Action OnCmdRefreshSkipBlacklist(int client, int args)
{
	skipBlacklist.Clear();
	LoadSkipBlacklist();
	
	ReplyToCommand(client, PREFIX ... "Refreshed objective skip blacklist");
	return Plugin_Handled;
}

int GetOffsetOrFail(GameData gamedata, const char[] key)
{
	int offset = gamedata.GetOffset(key);
	if (offset == -1)
	{
		SetFailState("Failed to find offset \"%s\"", key);
	}
	return offset;
}