#include <sourcemod>
#include <string>
#include <usermessages>
#include <tf2_stocks>

//#include "config.inc"
//#include "version.inc"
//[Vincenator] ^ these will contain the following, I assume
#define MAX_COMMAND_LENGTH 500
#define MAX_COMMANDS 100
#define GAME_START_DELAY 10
#define SETUP_CLASSES_TIME 10
#define PLUGIN_VERSION "0.1"
//[Vincenator] ^ I'm arbitrarily setting these five

public Plugin:myinfo = {
	name = "PubComp",
	author = "The PubComp Team",
	description = "",
	version = PLUGIN_VERSION,
	url = "http://pubcomp.com/"
};

new bool:tickStarted = false; //I don't know how this works
new bool:pubCompBotKicked = false; //I don't know how this works
new String:gameCommands[MAX_COMMANDS][MAX_COMMAND_LENGTH];
new commandCount = 0;

new numberOfPlayersAddSteam=0;
new numberOfPlayersDropped=0;
new numberOfPlayersAddTeam=0;
new numberOfPlayersAddClass=0;
new numberOfPlayersAddPositions=0;
new numberOfClassLimit=1;

new String:steamIDforTeamsAndClasses[32][20];
new String:droppedPlayerSteamID[32][20];
new teamForPlayer[32];
new classForPlayer[32];
new positionsForPlayer[32][9];
new classLimit[10];

new bool:hasGameStarted=false;
new bool:canPlayersReady=false;
new bool:waitingForPlayer=false;

new bool:playerReady[MAXPLAYERS+1];
new  playerSubVote[MAXPLAYERS+1];
new Handle:gameCountdown = INVALID_HANDLE;
new Handle:RevoteWaitTimer = INVALID_HANDLE;
new Handle:EndSubVoteTimer = INVALID_HANDLE;
new Handle:UnpauseGameTimer = INVALID_HANDLE;


new playersNeeded = 1; //server should set this; make a command or cvar

new votesToSub=0;
new votesToWait=0;

// These functions and globals are for setting, activating and
// deactivating the desired pre-game/pause warmup mode.

#define NUM_WARMUP_MODES 2
#define ENABLE 0
#define DISABLE 1
new String:warmupModes[NUM_WARMUP_MODES + 1][16] = {"NONE", "SOAP", "MGE"};
new activeWarmupMode;
new String:warmupActivationCommands[NUM_WARMUP_MODES + 1][2][MAX_COMMAND_LENGTH] = {
	{"", ""}, //can't go directly from soap to nothing without a map change because soap disables the control points
	{"sm plugins load soap_tf2dm", "sm plugins unload soap_tf2dm"},
	{"sm plugins load mgemod", "sm plugins unload mgemod"}
};


public OnPluginStart() {
        RegConsoleCmd("pubcomp_set_player_team", CommandSetPlayerTeam, "",FCVAR_PLUGIN); // 2 is red, 3 is blue
        RegConsoleCmd("pubcomp_set_player_class", CommandSetPlayerClass, "",FCVAR_PLUGIN); // 1 is scout, ... , 9 is spy
        RegConsoleCmd( "pubcomp_set_player_positions", CommandSetPlayerPositions, "", FCVAR_PLUGIN); // 2-5-8 is soldier, heavy and sniper; include main class
        RegConsoleCmd("pubcomp_set_class_limit", CommandSetClassLimit, "",FCVAR_PLUGIN); //must be entered in order: scout, soldier, pyro, ... spy (total of 9 times)
        RegConsoleCmd( "pubcomp_add_steamid", CommandAddSteamID, "", FCVAR_PLUGIN );
        RegConsoleCmd( "pubcomp_add_game_command", CommandAddGameCommand, "", FCVAR_PLUGIN);
        RegConsoleCmd( "pubcomp_set_warmup_mod", CommandSetWarmupMod, "", FCVAR_PLUGIN);
        RegConsoleCmd("pubcomp_reset_game_setup", CommandResetGameSetup, "",FCVAR_PLUGIN);//resets steamids, team, class, positions, class limits, and game commands
        RegConsoleCmd("pubcomp_kick_all_nonwhitelist", CommandKickAllNonwhitelist, "", FCVAR_PLUGIN);
        RegConsoleCmd("pubcomp_let_players_ready", CommandLetPlayersReady, "",FCVAR_PLUGIN);//allows players to .ready up and start the game

        RegConsoleCmd( "say", ReadyUnready, "", FCVAR_PLUGIN);
        //ServerCommand("mp_waitingforplayers_cancel 1"); //eventually I should find a nice place for this for soap dm; totally unimportant though
        HookEvent("player_changeclass",PlayerChangeClass,EventHookMode_Pre);
        //we need to stop players from switching teams (to the other or to spec) if the hasGameStarted - hook playerteam and return plugin handled if hasGameStarted
        HookEvent("tf_game_over",TFGameOver,EventHookMode_Pre);

        ServerCommand("mp_tournament 0");
        ServerCommand("pubcomp_reset_game_setup"); //I'll rewrite this line so as to call the command internally.. /lazy
}

bool:findSteamID( const String:id[] ) { //is player whitelisted
	for (new i=0; i<numberOfPlayersAddSteam; i++){
		if(StrEqual(steamIDforTeamsAndClasses[i],id)){
			return true;
		}
	}
	return false;
}

public Action:CommandResetGameSetup(client, args){
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to reset the game setup.", client );
		return Plugin_Stop;
	}

//resets steamids, team, class, positions, class limits, and game commands
//warmup mod is just overridden and therefore doesn't need to be reset
	numberOfPlayersAddSteam=0;
	numberOfPlayersDropped=0;
	numberOfPlayersAddTeam=0;
	numberOfPlayersAddClass=0;
	numberOfPlayersAddPositions=0;
	numberOfClassLimit=1;

	for(new i=0; i<32; i++){
		steamIDforTeamsAndClasses[i][0]=0; //steamid
		droppedPlayerSteamID[i][0]=0; //list of dropped players
		teamForPlayer[i]=-1; //team
		classForPlayer[i]=-1; //class
		for (new b=0; b<9; b++){
			positionsForPlayer[i][b]=0; //positions
		}
	}
	for(new i=0; i<10; i++){
		classLimit[i]=-1; //class limit
	}
	for(new i=0; i<commandCount; i++){ //game commands
		gameCommands[i][0]=0;
	}
	commandCount = 0;
	for(new i=1; i<MAXPLAYERS+1; i++){ //lets the players ready up, to start the new match
		playerReady[i]=false;
	}
	for(new i=1; i<MAXPLAYERS+1; i++){ //shows players haven't voted about a sub
		playerSubVote[i]=0;
	}

	return Plugin_Handled;
}

public Action:CommandKickAllNonwhitelist(client, args){
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to reset the game setup.", client );
		return Plugin_Stop;
	}
	new String:currentSteamID[20];
	for (new i =1; i<=MaxClients; i++){
		if(IsClientConnected(i)){
			currentSteamID="";
			GetClientAuthString(i, currentSteamID,sizeof(currentSteamID));
			new bool:isWhitelisted=false;
			for (new a=0; a<numberOfPlayersAddSteam; a++){
				if(StrEqual(steamIDforTeamsAndClasses[a],currentSteamID)){
					isWhitelisted=true;
				}
			}
			if(isWhitelisted==false && IsClientConnected(i)){
				KickClient(i, "You are not whitelisted for the new match" );
			}
		}
	}
	return Plugin_Handled;
}

public Action:CommandLetPlayersReady(client,args){
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to let players ready.", client );
		return Plugin_Stop;
	}
	canPlayersReady=true;
	PrintToChatAll("You may now type .ready and start the game.");
	return Plugin_Handled;
}

public Action:CommandSetPlayerPositions(client,args){
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to set player positions.", client );
		return Plugin_Stop;
	}
	new String:classBuffer[9][2];
	new String:positionsBuffer[18]; // "1-2-3-4-5-6-7-8-9" = 17 + terminator
	GetCmdArgString(positionsBuffer, sizeof(positionsBuffer ) );
	new numberOfClasses = ExplodeString(positionsBuffer, "-", classBuffer,9,2);
	for (new i=0; i<numberOfClasses; i++){
		positionsForPlayer[numberOfPlayersAddPositions][i]=StringToInt(classBuffer[i]);
		//the player number 'numberOfPlayersAddPositions' has at least one and up to nine classes in the above array
	}

	numberOfPlayersAddPositions++;
	return Plugin_Handled;
}


public Action:CommandSetPlayerClass(client,args){
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to set player classes.", client );
		return Plugin_Stop;
	}
	new String:classBuffer[2];
	GetCmdArgString(classBuffer, sizeof( classBuffer ) );
	new classNumber=StringToInt(classBuffer);
	classForPlayer[numberOfPlayersAddClass]=classNumber;
	numberOfPlayersAddClass++;
	return Plugin_Handled;
}

public Action:CommandSetPlayerTeam(client,args){
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to set player teams.", client );
		return Plugin_Stop;
	}
	new String:teamBuffer[2];
	GetCmdArgString( teamBuffer, sizeof( teamBuffer ) );
	new teamNumber=StringToInt(teamBuffer);
	teamForPlayer[numberOfPlayersAddTeam]=teamNumber;
	numberOfPlayersAddTeam++;
	return Plugin_Handled;
}

public Action:CommandSetClassLimit(client,args){
	if(numberOfClassLimit>9){
		LogMessage("Cannot add a class limit for the 10th class (called too many times; reset limits first).");
		return;
	}
	new String:limitBuffer[3];
	GetCmdArgString(limitBuffer,sizeof(limitBuffer));
	new limit=StringToInt(limitBuffer);
	classLimit[numberOfClassLimit]=limit;
	numberOfClassLimit++;
}

public PutPlayersOnTeam()
{
	new String:currentSteamID[20];
	for (new i =1; i<=MaxClients; i++){
		for (new a=0; a<numberOfPlayersAddSteam; a++){
			currentSteamID="";
			if(IsClientConnected(i)){
				GetClientAuthString(i, currentSteamID,sizeof(currentSteamID));
				if(StrEqual(currentSteamID,steamIDforTeamsAndClasses[a])){
					if(teamForPlayer[a]==-1){
						LogMessage("This player was not assigned a team.");
						return;
					} else if(teamForPlayer[a]==2){
						PrintToChat(i,"You are being moved to the red team");
					}else if(teamForPlayer[a]==3){
						PrintToChat(i,"You are being moved to the blue team");
					}
					ChangeClientTeam(i,teamForPlayer[a]);
				}
			}
		}
	}
}

public PutPlayersOnClass()
{
	new TFClassType:newClass;
	new String:className[10];
	new String:currentSteamID[20];
	for (new i =1; i<=MaxClients; i++){
		for (new a=0; a<numberOfPlayersAddSteam; a++){
			currentSteamID="";
			if(IsClientConnected(i)){
				GetClientAuthString(i, currentSteamID,sizeof(currentSteamID));
				if(StrEqual(currentSteamID,steamIDforTeamsAndClasses[a])){

					switch (classForPlayer[a])
					{
						case -1:
						{
							LogMessage("This player was not assigned a class.");
							return;

						}
						case 1:
						{
							newClass=TFClass_Scout;
							className="scout";
						}
						case 2:
						{
							newClass=TFClass_Soldier;
							className="soldier";
						}
						case 3:
						{
							newClass=TFClass_Pyro;
							className="pyro";
						}
						case 4:
						{
							newClass=TFClass_DemoMan;
							className="demoman";
						}
						case 5:
						{
							newClass=TFClass_Heavy;
							className="heavy";
						}
						case 6:
						{
							newClass=TFClass_Engineer;
							className="engineer";
						}
						case 7:
						{
							newClass=TFClass_Medic;
							className="medic";
						}
						case 8:
						{
							newClass=TFClass_Sniper;
							className="sniper";
						}
						case 9:
						{
							newClass=TFClass_Spy;
							className="spy";
						}
						default:
						{	//(if player wasn't given a class, they can play pyro. sure.) EDIT: this should never be called now that I have the -1 case
							newClass=TFClass_Pyro; //for some reason it doesn't recognize TFClass_PROro..
							className="proro";
						}
					}
					TF2_SetPlayerClass(i, newClass, false, true);
					PrintToChat(i,"Your class is being changed to %s.",className);
				}
			}
		}
	}
}

bool:IsFull(team,classNumber, TFClassType:class){
	new count=1;
	if(classLimit[classNumber]==-1){
		LogMessage("This class was not assigned a limit.");
		return false;
	}
	new limit=classLimit[classNumber]
	for(new i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && (GetClientTeam(i) == team) && (TF2_GetPlayerClass(i) == class)){
			count++;
		}
		if(count>limit){
			return true;
		}
	}
	return false;
}

public Action:CommandAddSteamID( client, args ) {
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to add users to the whitelist.", client );
		return Plugin_Stop;
	}

	if ( !tickStarted ) { //[Vincenator] What does this do?? Do we need the server 'ticking' for any reason besides the steamidexpire, which I've since removed?
		CreateFakeClient( "PubComp" ); // Will be auto-kicked; we need this to start the server ticking.
		tickStarted = true;
	}

	decl String:id[20];
	GetCmdArgString( id, sizeof( id ) );

	if(numberOfPlayersAddSteam>31){
		LogMessage( "Failed to add %s to the whitelist. Whitelist is full.", id );
		return Plugin_Handled;
	}
	steamIDforTeamsAndClasses[numberOfPlayersAddSteam]=id;
	numberOfPlayersAddSteam++;
	LogMessage( "Added %s to the whitelist.", id );

	return Plugin_Handled;
}

public Action:TFGameOver(Handle: event, const String:name[], bool:dontBroadcast){
        ServerCommand("mp_restartgame 1"); //restarting the game (in 1 second) stops it from needing tournament mode to not change maps
        //Bug: the scoreboard pops up and needs to be manually closed (hitting Tab once)
        CreateTimer(1.0, Timer:EndTournamentGame); //as soon as the game can have tournament off without changing maps, get rid of it - it is unnecessary and looks distracting
        LogMessage("Match over.")
        PrintToChatAll("Game over!");
}

public Timer:EndTournamentGame(Handle:data){
        ServerCommand("mp_tournament 0");
        ServerCommand(warmupActivationCommands[activeWarmupMode][ENABLE]);
        PrintToChatAll("Entering warmup mode.");
        //set the timelimit to unlimited so the map never changes?
        hasGameStarted=false;

        //now we need to reset some things to prepare for the next match, which will give us input
        //actually, let the omniscient web server call the CommandResetGameSetup command whenever it wants to
}


//It appears I might need to have the same code for playerspawn and playerteam - leave it for now, see if anyone can break it ;)
//Bug: under same circumstances, the player's viewmodel is messed up. This is probably related to the above comment.
public Action:PlayerChangeClass(Handle:event, const String:name[], bool:dontBroadcast) {
//Bug: the text says "*You will respawn as [class]" immediately after "You cannot play [class]" when outside the spawn room
	if(!hasGameStarted){
		return;
	}

	new userid = GetEventInt(event, "userid");
	new TFClassType: class = TFClassType:GetEventInt(event, "class");
	new user = GetClientOfUserId (userid);
	new TFClassType: oldClass = TF2_GetPlayerClass(user);
	new team = GetClientTeam(user);

	if ((class == oldClass) || (class == TFClass_Unknown)){
		return;
	}
	new String:currentSteamID[20];
	for (new a=0; a<numberOfPlayersAddPositions; a++){
		currentSteamID="";
		if(IsClientConnected(user)){
			GetClientAuthString(user, currentSteamID,sizeof(currentSteamID));
			if(StrEqual(currentSteamID,steamIDforTeamsAndClasses[a])){
				new canPlayClass[10]; // use indexes 1-9
				new i=0;
				while(positionsForPlayer[a][i]){
					canPlayClass[positionsForPlayer[a][i]]=true;
					i++;
				}
				if(class==TFClass_Scout){
					if(IsFull(team,1,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"Your team cannot have any more scouts.");
					}
					if(!canPlayClass[1]){
						TF2_SetPlayerClass(user,oldClass,true,true); //third should be false if player died, maybe..
						PrintToChat(user,"You cannot play scout.");
					}
				}else if(class==TFClass_Soldier){
					if(IsFull(team,2,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"Your team cannot have any more soldiers.");
					}
					if(!canPlayClass[2]){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"You cannot play soldier.");
					}
				}else if(class==TFClass_Pyro){
					if(IsFull(team,3,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"Your team cannot have any more pyros.");
					}
					if(!canPlayClass[3]){
						TF2_SetPlayerClass(user,oldClass,true,true); 
						PrintToChat(user,"You cannot play pyro.");
					}
				}else if(class==TFClass_DemoMan){
					if(IsFull(team,4,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"Your team cannot have any more demomen.");
					}
					if(!canPlayClass[4]){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"You cannot play demoman.");
					}
				}else if(class==TFClass_Heavy){
					if(IsFull(team,5,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"Your team cannot have any more heavies.");
					}
					if(!canPlayClass[5]){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"You cannot play heavy.");
					}
				}else if(class==TFClass_Engineer){
					if(IsFull(team,6,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"Your team cannot have any more engineers.");
					}
					if(!canPlayClass[6]){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"You cannot play engineer.");
					}
				}else if(class==TFClass_Medic){
					if(IsFull(team,7,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"Your team cannot have any more medics.");
					}
					if(!canPlayClass[7]){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"You cannot play medic.");
					}
				}else if(class==TFClass_Sniper){
					if(IsFull(team,8,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"Your team cannot have any more snipers.");
					}
					if(!canPlayClass[8]){
						TF2_SetPlayerClass(user,oldClass,true,true); 
						PrintToChat(user,"You cannot play sniper.");
					}
				}else if(class==TFClass_Spy){
					if(IsFull(team,9,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"Your team cannot have any more spies.");
					}
					if(!canPlayClass[9]){
						TF2_SetPlayerClass(user,oldClass,true,true); 
						PrintToChat(user,"You cannot play spy.");
					}
				}
			}
		}
	}
}

public OnClientAuthorized( client, const String:auth[] ) {
	// Don't kick the SourceTV bot or the replay bot.
	if ( StrEqual( auth, "BOT" ) ) {
		decl String:botName[MAX_NAME_LENGTH];
		GetClientName( client, botName, MAX_NAME_LENGTH );
		decl String:sourceTV[MAX_NAME_LENGTH];
		new Handle:_sourceTV = FindConVar( "tv_name" );
		GetConVarString( _sourceTV, sourceTV, MAX_NAME_LENGTH );
		CloseHandle( _sourceTV );
		if ( StrEqual( botName, "replay" ) || StrEqual( botName, sourceTV ) )
			return;
	}

	new bool:foundSteamID = findSteamID( auth );
	if ( !foundSteamID ) {
		KickClient( client, "Please join from the PubComp web interface" );
	}

	new String:currentSteamID[20];
	currentSteamID="";
	GetClientAuthString(client, currentSteamID,sizeof(currentSteamID));
	for (new a=0; a<numberOfPlayersDropped; a++){
		if(StrEqual(droppedPlayerSteamID[a],currentSteamID)){
			droppedPlayerSteamID[a][0]=0;
			numberOfPlayersDropped--;
			//to-do: move every droppedPlayerSteamID down one index in the array
			//cancel waiting timer (if it's for this player) - currently this assumes only one player at a time can drop; needs to be fixed
			if(EndSubVoteTimer!=INVALID_HANDLE){
				KillTimer(EndSubVoteTimer);
			}
			if(RevoteWaitTimer!=INVALID_HANDLE){
				KillTimer(RevoteWaitTimer);
			}
			for(new i=1; i<MAXPLAYERS+1; i++){ //players haven't voted about a sub
				playerSubVote[i]=0;
			}
			decl String:playerName[MAX_NAME_LENGTH];
			GetClientName( client, playerName, MAX_NAME_LENGTH );
			LogMessage("Player %s has rejoined, no need for sub", playerName);
			PrintToChatAll("Player %s has rejoined; canceling sub vote. Game unpauses in 10 seconds.", playerName);
			UnpauseGameTimer=CreateTimer(10.0,Timer:UnpauseGame);
			waitingForPlayer=false;
		}
	}


	

}

public OnClientDisconnect_Post( client ) {
	if ( !pubCompBotKicked ) {
		pubCompBotKicked = true;
		return;
	}
}

public OnClientDisconnect(client){
	if(hasGameStarted){
		decl String:playerName[32];
		GetClientName(client, playerName, sizeof(playerName));

		new String:currentSteamID[20];
		currentSteamID="";
		GetClientAuthString(client, currentSteamID,sizeof(currentSteamID));

		if(UnpauseGameTimer!=INVALID_HANDLE){
			KillTimer(UnpauseGameTimer);
		}

		if(numberOfPlayersDropped<32){
			droppedPlayerSteamID[numberOfPlayersDropped]=currentSteamID;
			numberOfPlayersDropped++;
		}else{
			LogMessage("List of dropped players is full");
		}

		LogMessage("Pausing because %s disconnected, steamid %s", playerName, currentSteamID);
		ServerCommand("sv_pausable 1");//does this work --v ?
		FakeClientCommand(client,"pause");//this is the only way besides creating a fake client to pause the server as far as I can tell
		FakeClientCommand(client,"say disconnected - pausing");
		PrintToChatAll("Type .sub to replace with a sub or .wait to wait 2 minutes for rejoin"); //problem is, players can only say one message
		//ServerCommand("sv_pausable 0"); //this needs to be delayed or something
		//don't let anyone pause the server, though

		waitingForPlayer=true;
		EndSubVoteTimer=CreateTimer(30.0, Timer:EndSubVote);//30 seconds to vote - add currentSteamID with a datapack :(
	}
}

public Timer:UnpauseGame(Handle:data){
	LogMessage("Unpausing game");
	PrintToChatAll("Unpausing game");
	ServerCommand("sv_pausable 1");
	FakeClientCommand(1,"pause");//this is the only way besides creating a fake client to pause the server as far as I can tell
	FakeClientCommand(1,"say disconnected - pausing");
	//ServerCommand("sv_pausable 0"); //this needs to be delayed or something
}

public Timer:RevoteWait(Handle:data){
	CreateTimer(30.0,Timer:EndSubVote);//30 seconds to vote
	for(new i=1; i<MAXPLAYERS+1; i++){ //players haven't voted about a sub
		playerSubVote[i]=0;
	}
	PrintToChatAll("Type .sub to replace with a sub or .wait to wait 2 minutes for rejoin - 30 seconds to vote");
}

public Timer:EndSubVote(Handle:data){ //should have steamid
	if (votesToSub>= votesToWait) { //if there's a tie, call a sub
		LogMessage("Requesting sub %d-%d",votesToSub,votesToWait);
		PrintToChatAll("Requesting sub"); //steamid
	}else{
		LogMessage("Waiting 2 minutes to revote %d-%d",votesToSub,votesToWait);
		RevoteWaitTimer=CreateTimer(120.0, Timer:RevoteWait);
		PrintToChatAll("Waiting for the player for 2 more minutes");
	}
}

public OnClientPutInServer( client ) {
	decl String:map[PLATFORM_MAX_PATH];
	GetCurrentMap( map, PLATFORM_MAX_PATH );
	if ( StrEqual( map, "mge_training_v7" ) ) {
		FakeClientCommand( client, "say /first" );
	}
}


// These functions allow the rcon user to add settings that will take
// effect when the actual match begins.

// Add a command to be executed when the match begins.
public Action:CommandAddGameCommand( client, args ) {
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to add game commands.", client );
		return Plugin_Stop;
	}

	decl String:command[MAX_COMMAND_LENGTH];
	GetCmdArgString( command, sizeof( command ) );

	if ( commandCount + 1 == MAX_COMMANDS ) {
		LogMessage( "Failed to add command \"%s\" to buffer; Command list is full.", command );
		return Plugin_Stop;
	}

	strcopy( gameCommands[commandCount], MAX_COMMAND_LENGTH, command );
	commandCount++;
	return Plugin_Handled;
}

// Internal function that will execute the commands when the match begins.
public ExecuteGameCommands() {
	for ( new i = 0; i < commandCount; i++ ) {
		ServerCommand(gameCommands[i]);
	}
	commandCount = 0;
}



public Action:CommandSetWarmupMod( client, args ) {
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to change the warmup mod.", client );
		return Plugin_Stop;
	}

	decl String:modeName[20];
	GetCmdArgString( modeName, sizeof( modeName ) );

	new oldWarmupMode=activeWarmupMode;
	activeWarmupMode = -1;

	for (new i = 0; i < NUM_WARMUP_MODES + 1; i++) {
		if (strcmp(modeName, warmupModes[i]) == 0) {
			activeWarmupMode = i;
			if(i==oldWarmupMode){
				return Plugin_Stop; //we're already on this warmup mod, no need to reload it
			}
		}
		ServerCommand(warmupActivationCommands[i][1]); //unload
	}
	if (activeWarmupMode == -1) {
		LogMessage("Could not find warmup mode \"%s\".", modeName);
		return Plugin_Stop;
	}
	ServerCommand(warmupActivationCommands[activeWarmupMode][0]); //load

	return Plugin_Handled;
}

public Action:ReadyUnready(client, args) {
	decl String:text[192];
	GetCmdArg(1, text, sizeof(text));

	// ready unready vote
	if (strcmp(text, ".ready") == 0 || strcmp(text, ".gaben") == 0 || strcmp(text, ".unready") == 0 || strcmp(text, ".notready") == 0) {
		if(hasGameStarted || !canPlayersReady || !(GetClientTeam(client)==2 || GetClientTeam(client)==3)){
			return Plugin_Continue;
		}
		new bool:didSwitch=false;
		if (strcmp(text, ".ready") == 0 || strcmp(text, ".gaben") == 0) {
			if(playerReady[client]!=true){
				didSwitch=true;
				decl String:playerName[32];
				GetClientName(client, playerName, sizeof(playerName));
				PrintToChatAll("Player %s is now ready.", playerName);
			}
			playerReady[client] = true;
		}			

		if (strcmp(text, ".notready") == 0 || strcmp(text, ".unready") == 0) {
			if(playerReady[client]==true){
				didSwitch=true;
				decl String:playerName[32];
				GetClientName(client, playerName, sizeof(playerName));
				PrintToChatAll("Player %s is no longer ready.", playerName);
			}
			playerReady[client] = false;
		}		

		if(didSwitch==false){
			return Plugin_Continue; //if the player's just being silly, don't reset the timer or restate that players are ready
		}

		new readyCount = 0;
		for (new i = 0; i < MAXPLAYERS+1; i++) {
			readyCount += playerReady[i] ? 1 : 0;
		}
		if (readyCount >= playersNeeded) {
			gameCountdown = CreateTimer(float(GAME_START_DELAY), Timer:PubCompStartGame);
			new seconds = GAME_START_DELAY % 60;
			new minutes = GAME_START_DELAY / 60;
			PrintToChatAll("%d players are now ready.", readyCount);
			if (minutes == 0) {
				PrintToChatAll("Game starts in %d seconds.", seconds);
			} else if (seconds == 0) {
				PrintToChatAll("Game starts in %d minutes.", minutes);
			} else {
				PrintToChatAll("Game starts in %d minutes and %d seconds.", minutes, seconds);
			}
		} else if (gameCountdown != INVALID_HANDLE) {
			KillTimer(gameCountdown);
			gameCountdown = INVALID_HANDLE;
			PrintToChatAll("Down to %d ready player%s.  Countdown canceled.", readyCount, readyCount == 1 ? "" : "s");
		}	

	//sub wait vote
	}else  if (strcmp(text, ".sub") == 0 || strcmp(text, ".wait") == 0){
		if(!hasGameStarted || waitingForPlayer || !(GetClientTeam(client)==2 || GetClientTeam(client)==3)){
			return Plugin_Continue;
		}
		new bool:didSwitch=false;
		if (strcmp(text, ".sub") == 0) {
			if(playerSubVote[client]!=1){
				didSwitch=true;
				decl String:playerName[32];
				GetClientName(client, playerName, sizeof(playerName));
				PrintToChatAll("Player %s has voted for a sub.", playerName);
			}
			if(didSwitch==true){
				playerSubVote[client] = 1;
				votesToSub++;
			}
		}else if (strcmp(text, ".wait") == 0) {
			if(playerSubVote[client]!=2){
				didSwitch=true;
				decl String:playerName[32];
				GetClientName(client, playerName, sizeof(playerName));
				PrintToChatAll("Player %s has voted to wait.", playerName);
			}
			if(didSwitch==true){
				playerSubVote[client] = 2;
				votesToWait++;
			}
        		}
		if(didSwitch==false){
			return Plugin_Continue; //if the player's just being silly, don't reset the timer or restate that players are ready
		}
	}
	return Plugin_Continue;
}

public Timer:PubCompStartGame(Handle:data) {
        // Tell node we're starting a game here.  Node should already
        // have the steamids of the players in the game, and their map
        // and position preferences will be entered through the web,
        // so it will have those as well.  So we don't have to send
        // anything except a message that we're starting the game.
        //
        // It should send us (through rcon console commands) team
        // assignments and position assignments.
        LogMessage( "PubComp: Requesting team and position assignments..." );
        ServerCommand("mp_tournament 1");
        ServerCommand(warmupActivationCommands[activeWarmupMode][DISABLE]);

        hasGameStarted=true;
        canPlayersReady=false;
        for(new i=1; i<MAXPLAYERS+1; i++){
                playerReady[i]=false;
        }
        PutPlayersOnTeam();
        ServerCommand("mp_restartgame 1");
        CreateTimer(1.0, Timer:PubCompStartGame2);
}

public Timer:PubCompStartGame2(Handle:data) {
        PutPlayersOnClass();
        PrintCenterTextAll("Setup Classes.  Game will start in %d seconds.", SETUP_CLASSES_TIME);
        LogToGame("Setup Classes.  Game will start in %d seconds.", SETUP_CLASSES_TIME);
//should also stop players from switching teams - mp_teams_unbalance_limit or something
        ServerCommand("mp_restartgame %d", SETUP_CLASSES_TIME); //should say "Game is Live" now, not one second after.. why does esea do it with a delay? seems stupid.
        CreateTimer(float(SETUP_CLASSES_TIME + 1), Timer:PubCompStartGame3);
}

public Timer:PubCompStartGame3(Handle:data) {
        ExecuteGameCommands();
        LogMessage("Match starting.")
        PrintCenterTextAll("----Game is LIVE----");
}