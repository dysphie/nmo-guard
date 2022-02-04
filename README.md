# [NMRiH] NMO Guard

Offers protection against some forms of objective chain breaking, such as unreachable items or skips.

## Installation

- [Install Sourcemod](https://wiki.alliedmods.net/Installing_sourcemod)
- Grab the latest zip from the [releases](https://github.com/dysphie/nmrih-team-healing/releases) section
- Extract the contents into `addons/sourcemod`
- Refresh the plugin list (`sm plugins refresh` or `sm plugins load nmo-guard` in server console)

## Recovering lost objective items

Players can vote to recover lost objective items via `sm_softlock`. On a successful vote a clone of the lost item will spawn at its original coordinates.

![image](https://user-images.githubusercontent.com/11559683/121577277-be363880-c9ff-11eb-8ae2-10f4417090b2.png)

![image](https://user-images.githubusercontent.com/11559683/121577390-d908ad00-c9ff-11eb-9a9d-1375b19a0ef3.png)

## Recovering from objective skips

When an objective is completed ahead of time, the objective chain can attempt to fast-forward itself instead of becoming stuck. 

This doesn't always work, and can lead to issues on maps that fire "ObjectiveComplete" erroneously.
For this reason the functionality disabled by default (see CVars) and a blacklist is included in `configs/nmo-guard.cfg`. Objectives listed here won't fast-forward the objective chain if they're completed ahead of time.

```cpp
"nmoguard"
{
	"skip_blacklist"
	{
		// "map name" "objective name"
		
		// nmo_experiment tries to complete "Gather supplies before leaving" when the round starts
		"nmo_experiment_v3"			"12"
		"nmo_experiment_v3_fix"		"12"
	}
}
```

## Public Commands

- `sm_softlock` or `sm_sl`
  - Displays the softlock recovery interface

## Admin Commands

- `sm_objskip`
  - Skips the current objective 

- `sm_objskip_refresh_blacklist`
  - Refresh objective skip blacklist

## ConVars

- `sm_nmoguard_clone_show_blip` (1/0) (Default: 1)
  - Whether entity clones show a blip in the compass. Sometimes clones fail to glow so it's recommended to leave this on.

- `sm_nmoguard_clone_max_count` (Default: 2)
  - How many times an entity can be cloned
  
- `sm_nmoguard_allow_obj_skip`  (1/0) (Default: 0)
  - Whether to allow the objective chain to fix itself after an objective is completed ahead of time
  
- `sm_nmoguard_allow_item_vote`  (1/0) (Default: 1)
  - Whether to allow players to vote to recover lost objective items
