# nmo-guard
Allows recovery of lost objective items thru voting.
On a successful vote a clone of the lost item will spawn at its original coordinates.

![image](https://user-images.githubusercontent.com/11559683/121577277-be363880-c9ff-11eb-8ae2-10f4417090b2.png)

![image](https://user-images.githubusercontent.com/11559683/121577390-d908ad00-c9ff-11eb-9a9d-1375b19a0ef3.png)

## Requirements
- Sourcemod 1.11 Build 6646 or higher

## Commands

- `sm_softlock` or `sm_sl`
  - Displays the softlock recovery interface


## ConVars

- `sm_nmoguard_clone_show_blip` (1/0) (Default: 1)
  - Whether entity clones show a blip in the compass. Sometimes clones fail to glow so it's recommended to leave this on.

- `sm_nmoguard_clone_max_count` (Default: 2)
  - How many times an entity can be cloned
