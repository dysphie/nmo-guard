// TODO:
// - Replace with vscript
// - Remove address+ operator, may break with future SM updates

stock Address operator+(Address base, int off) {
	return base + view_as<Address>(off);
}

methodmap AddressBase {
	property Address addr {
		public get() { 
			return view_as<Address>(this); 
		}
	}
}

int offs_UtlVectorSize;
int offs_UtlVectorElems;

methodmap UtlVector < AddressBase 
{
	public UtlVector(Address addr) {
		return view_as<UtlVector>(addr);
	}

	property int size 
	{
		public get() 
		{
			return LoadFromAddress(this.addr + offs_UtlVectorSize, NumberType_Int32);
		}
	}

	property Address elements {
		public get() {
			Address pElements = LoadFromAddress(this.addr + offs_UtlVectorElems, NumberType_Int32);
			return view_as<Address>(pElements);
		}
	}

	public any Get(int idx, int elemSize = 0x4) {
		return LoadFromAddress(this.elements + idx * elemSize, NumberType_Int32);
	}
}

methodmap ObjectiveBoundary < AddressBase {

	public ObjectiveBoundary(Address addr) {
		return view_as<ObjectiveBoundary>(addr);
	}

	public void Finish() {
		ObjectiveBoundary_Finish(this.addr);
	}
}

int offs_ObjectiveID;
int offs_ObjMgrCurObjIdx;
int offs_ObjMgrCurObj;
int offs_ObjMgrObjChain;

methodmap Objective < AddressBase 
{
	public Objective(Address addr) 
	{
		return view_as<Objective>(addr);
	}

	property int ID 
	{
		public get() 
		{ 
			return LoadFromAddress(this.addr + offs_ObjectiveID, NumberType_Int32);
		}
	}
}

methodmap ObjectiveManager < AddressBase {

	public ObjectiveManager(Address addr) 
	{
		return view_as<ObjectiveManager>(addr);
	}

	property ObjectiveBoundary currentObjectiveBoundary 
	{
		public get() 
		{
			Address addr = view_as<Address>(LoadFromAddress(this.addr + 0x7C, NumberType_Int32));
			return ObjectiveBoundary(addr);
		}
	}

	property int currentObjectiveIndex 
	{
		public get() 
		{
			return LoadFromAddress(this.addr + offs_ObjMgrCurObjIdx, NumberType_Int32);
		}

		public set(int value) 
		{
			StoreToAddress(this.addr + offs_ObjMgrCurObjIdx, value, NumberType_Int32);
		}
	}

	property Objective currentObjective 
	{
		public get() 
		{
			Address addr = view_as<Address>(LoadFromAddress(this.addr + offs_ObjMgrCurObj, NumberType_Int32));
			return Objective(addr);
		}
	}

	public bool GetObjectiveChain(ArrayList arr) 
	{
		UtlVector chain = UtlVector(this.addr + offs_ObjMgrObjChain);
		if (!chain)
			return false;

		int len = chain.size;
		for (int i; i < len; i++)
			arr.Push(chain.Get(i));

		return true;
	}

	public void StartNextObjective() 
	{
		ObjectiveManager_StartNextObjective(this.addr);
	}

	public void CompleteCurrentObjective() 
	{
		ObjectiveBoundary boundary = this.currentObjectiveBoundary;
		if (boundary)
			boundary.Finish();

		this.currentObjectiveIndex++;
		this.StartNextObjective();
	}
}

ObjectiveManager objMgr;

Handle boundaryFinishFn;
Handle startNextObjectiveFn;
bool ignoreObjHooks;
ArrayList objectiveChain;

void ObjectiveManager_LoadGameData(GameData gamedata)
{
	objMgr = ObjectiveManager(gamedata.GetAddress("CNMRiH_ObjectiveManager"));
	if (!objMgr)
		SetFailState("Failed to resolve address of CNMRiH_ObjectiveManager");

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CNMRiH_ObjectiveBoundary::Finish");
	boundaryFinishFn = EndPrepSDKCall();
	if (!boundaryFinishFn)
		SetFailState("Failed to resolve address of CNMRiH_ObjectiveBoundary::Finish");

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CNMRiH_ObjectiveManager::StartNextObjective");
	startNextObjectiveFn = EndPrepSDKCall();
	if (!startNextObjectiveFn)
		SetFailState("Failed to resolve address of CNMRiH_ObjectiveManager::StartNextObjective");
	
	offs_ObjectiveID = GetOffsetOrFail(gamedata, "Objective::m_iId");
	offs_UtlVectorSize = GetOffsetOrFail(gamedata, "UtlVector::m_Size");
	offs_ObjMgrCurObjIdx = GetOffsetOrFail(gamedata, "CNMRiH_ObjectiveManager::_currentObjectiveIndex");
	offs_ObjMgrCurObj = GetOffsetOrFail(gamedata, "CNMRiH_ObjectiveManager::_currentObjective");
	offs_ObjMgrObjChain = GetOffsetOrFail(gamedata, "CNMRiH_ObjectiveManager::_objectiveChain");
	offs_UtlVectorElems = GetOffsetOrFail(gamedata, "UtlVector::m_pElements");
}