#include <sdktools>
#include <sourcemod>

#pragma newdecls required
#pragma semicolon 1


enum struct EntOutput
{
	int idStamp;
	char externalName[128];
	char target[128];
	char targetinput[128];
	char parameter[128];
	int timesToFire;
	float delay;
}


#define FTYPEDESC_OUTPUT 0x0010  // from sdk/public/datamap.h

Handle fnGetDataDescMap;

// 00000000 typedescription_t struc ; (sizeof=0x34, align=0x4, copyof_1809)
// 00000000 fieldType       dd ?           
// 00000004 fieldName       dd ?           
// 00000008 fieldOffset     dd 2 dup(?)    
// 00000010 fieldSize       dw ?           
// 00000012 flags           dw ?
// 00000014 externalName    dd ?           
// 00000018 pSaveRestoreOps dd ?           
// 0000001C inputFunc       dd ?           
// 00000020 td              dd ?           
// 00000024 fieldSizeInBytes dd ?          
// 00000028 override_field  dd ?           
// 0000002C override_count  dd ?           
// 00000030 fieldTolerance  dd ?           
// 00000034 typedescription_t ends

int offs_typedescriptiont_flags;
int offs_dataMap_dataDesc;
int offs_dataMap_baseMap;
int offs_GetDataDescMap;
int offs_dataMap_dataNumFields;
int sizeof_descriptiont;
int offs_typedescriptiont_extName;
//int offs_typedescriptiont_fieldName;
int offs_typedescriptiont_fieldOffset;

int offs_CBaseEntityOutput_m_ActionList;

int offs_CEventAction_m_iTarget;
int offs_CEventAction_m_iTargetInput;
int offs_CEventAction_m_iParameter;
int offs_CEventAction_m_flDelay;
int offs_CEventAction_m_nTimesToFire;
int offs_CEventAction_m_iIDStamp;
int offs_CEventAction_m_pNext;

void EntityOutputs_LoadGameData(GameData gamedata)
{
	offs_GetDataDescMap           = GetOffsetOrFail(gamedata, "CBaseEntity::GetDataDescMap");
	offs_dataMap_dataDesc         = GetOffsetOrFail(gamedata, "datamap_t::dataDesc");
	offs_typedescriptiont_extName = GetOffsetOrFail(gamedata, "typedescription_t::externalName");
	//offs_typedescriptiont_fieldName = GetOffsetOrFail(gamedata, "typedescription_t::fieldName");
	offs_typedescriptiont_fieldOffset = GetOffsetOrFail(gamedata, "typedescription_t::fieldOffset");
	offs_typedescriptiont_flags   = GetOffsetOrFail(gamedata, "typedescription_t::flags");
	offs_dataMap_dataNumFields    = GetOffsetOrFail(gamedata, "datamap_t::dataNumFields");
	sizeof_descriptiont           = GetOffsetOrFail(gamedata, "sizeof typedescription_t");
	offs_dataMap_baseMap          = GetOffsetOrFail(gamedata, "datamap_t::baseMap");

	offs_CBaseEntityOutput_m_ActionList = GetOffsetOrFail(gamedata, "CBaseEntityOutput::m_ActionList");

	offs_CEventAction_m_iTarget      = GetOffsetOrFail(gamedata, "CEventAction::m_iTarget");
	offs_CEventAction_m_iTargetInput = GetOffsetOrFail(gamedata, "CEventAction::m_iTargetInput");
	offs_CEventAction_m_iParameter   = GetOffsetOrFail(gamedata, "CEventAction::m_iParameter");
	offs_CEventAction_m_flDelay      = GetOffsetOrFail(gamedata, "CEventAction::m_flDelay");
	offs_CEventAction_m_nTimesToFire = GetOffsetOrFail(gamedata, "CEventAction::m_nTimesToFire");
	offs_CEventAction_m_iIDStamp     = GetOffsetOrFail(gamedata, "CEventAction::m_iIDStamp");
	offs_CEventAction_m_pNext        = GetOffsetOrFail(gamedata, "CEventAction::m_pNext");

	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetVirtual(offs_GetDataDescMap);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	if (!(fnGetDataDescMap = EndPrepSDKCall()))
	{
		SetFailState("Failed to set up GetDataDescMap call");
	}
}

void WriteEntityOutputs(ArrayList outputsList, int target)
{
	int maxOutputs = outputsList.Length;
	for (int i; i < maxOutputs; i++)
	{
		EntOutput output;
		outputsList.GetArray(i, output);

		char buffer[1024];
		FormatEx(buffer, sizeof(buffer), "%s %s:%s:%s:%d:%f", 
			output.externalName, output.target, output.targetinput, output.parameter, output.timesToFire, output.delay);
		SetVariantString(buffer);
		AcceptEntityInput(target, "AddOutput", target, target);
	}
}

ArrayList GetEntityOutputs(int entity)
{
	ArrayList arr = new ArrayList(sizeof(EntOutput));

	// Get this entity's datadesc map
	Address dataDescMap = SDKCall(fnGetDataDescMap, entity);

	// Also get the entity's base address, we'll use it later
	Address entityAddress = GetEntityAddress(entity);
	
	// Begin iterating the datadesc map
	while (dataDescMap)
	{
		int numFields = LoadFromAddress(dataDescMap + view_as<Address>(offs_dataMap_dataNumFields), NumberType_Int32);

		// Get the actual datadesc
		Address dataDesc  = LoadFromAddress(dataDescMap + view_as<Address>(offs_dataMap_dataDesc), NumberType_Int32);

		int maxBytes = numFields * sizeof_descriptiont;
		for (int i = 0; i < maxBytes; i += sizeof_descriptiont)
		{
			// We only care about entity outputs
			int flags = LoadFromAddress(dataDesc + view_as<Address>(offs_typedescriptiont_flags + i), NumberType_Int16);
			if (!(flags & FTYPEDESC_OUTPUT))
			{
				continue;
			}

			// This is the name used by Hammer (OnOpen instead of m_OnOpen, etc)
			Address pExternalName = LoadFromAddress(dataDesc + view_as<Address>(offs_typedescriptiont_extName + i), NumberType_Int32);
			if (!pExternalName) {
				continue;
			}

			char externalName[64];
			UTIL_StringtToCharArray(pExternalName, externalName, sizeof(externalName));
			
			// Retrieve the datadesc's offset, this is equivalent to FindDataMapInfo(entity, outputName)
			int offset = LoadFromAddress(dataDesc + view_as<Address>(offs_typedescriptiont_fieldOffset + i), NumberType_Int16);
			if (offset < 0)
			{
				LogError("Got bogus offset (%d) for entity output (%d)", offset, entity);
				continue;
			}

			// Finally we have this output's offset, we can walk its action list
			GetOutputActions(entityAddress, offset, arr, externalName);
		}

		dataDescMap = LoadFromAddress(dataDescMap + view_as<Address>(offs_dataMap_baseMap), NumberType_Int32);
	}

	// Now we have all the actions, we can send them to a new entity, save them, whatever
	// ...

	//PrintOutputs(arr);
	return arr;
}

// void PrintOutputs(ArrayList arr)
// {
// 	int maxOutputs = arr.Length;
// 	for (int i = 0; i < maxOutputs; i++)
// 	{
// 		EntOutput output;
// 		arr.GetArray(i, output, sizeof(output));
// 		PrintToServer("[%d] %s %s:%s:%s:%d:%f", 
// 			output.idStamp, output.externalName, output.target, output.targetinput, output.parameter, output.timesToFire, output.delay);
// 	}
// }

bool GetOutputActions(Address entityAddress, int outputOffset, ArrayList dest, const char[] key)
{
	// Get the CBaseEntityOutput at this offset
	Address output = entityAddress + view_as<Address>(outputOffset);
	if (!output) {
		return false;
	}

	// CBaseEntityOutput->m_ActionList
	Address actionlist = LoadFromAddress(output + view_as<Address>(offs_CBaseEntityOutput_m_ActionList), NumberType_Int32);
	if (!actionlist) {
		return false;
	}

	while (actionlist)
	{
		EntOutput data;
		strcopy(data.externalName, sizeof(data.externalName), key);

		Address m_iTarget = LoadFromAddress(actionlist + view_as<Address>(offs_CEventAction_m_iTarget), NumberType_Int32);
		Address m_iTargetInput = LoadFromAddress(actionlist + view_as<Address>(offs_CEventAction_m_iTargetInput), NumberType_Int32);
		Address m_iParameter = LoadFromAddress(actionlist + view_as<Address>(offs_CEventAction_m_iParameter), NumberType_Int32);

		data.timesToFire = LoadFromAddress(actionlist + view_as<Address>(offs_CEventAction_m_nTimesToFire), NumberType_Int32);
		data.delay = LoadFromAddress(actionlist + view_as<Address>(offs_CEventAction_m_flDelay), NumberType_Int32);
		data.idStamp = LoadFromAddress(actionlist + view_as<Address>(offs_CEventAction_m_iIDStamp), NumberType_Int32);

		// It's okay for these to be null, I guess
		if (m_iTarget) UTIL_StringtToCharArray(m_iTarget, data.target, sizeof(data.target));
		if (m_iTargetInput) UTIL_StringtToCharArray(m_iTargetInput, data.targetinput, sizeof(data.targetinput));
		if (m_iParameter) UTIL_StringtToCharArray(m_iParameter, data.parameter, sizeof(data.parameter));

		// CEventAction->m_flNext
		actionlist = LoadFromAddress(actionlist + view_as<Address>(offs_CEventAction_m_pNext), NumberType_Int32);

		// Finally save to our array of outputs
		dest.PushArray(data);
	}

	return true;
}

// ><(((°>
int UTIL_StringtToCharArray(Address stringt, char[] buffer, int maxlen)
{
	if (stringt == Address_Null)
	{
		ThrowError("string_t address is null");
	}

	if (maxlen <= 0)
	{
		ThrowError("Buffer size is negative or zero");
	}

	int max = maxlen - 1;
	int i   = 0;
	for (; i < max; i++)
	{
		buffer[i] = LoadFromAddress(stringt + view_as<Address>(i), NumberType_Int8);
		if (buffer[i] == '\0')
		{
			return i;
		}
	}

	buffer[i] = '\0';
	return i;
}
