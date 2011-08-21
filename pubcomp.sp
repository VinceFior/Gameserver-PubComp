#include <sourcemod>
#include <string>
#include <usermessages>
#include <tf2_stocks>

#include <sdktools>

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
new bool:waitingForSubVote=false;
new bool:canPause=false;

new bool:playerReady[MAXPLAYERS+1];
new  playerSubVote[MAXPLAYERS+1];
new Handle:gameCountdown = INVALID_HANDLE;

new Handle:countdownText=INVALID_HANDLE;
new countdownTime=0;
new String:countdownTextString[30]; //only needs to be 26 (for two-digit countdownTime)

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

        RegConsoleCmd("pause", ClientCommandPause, "",FCVAR_PLUGIN);//only let the pausebot pause
        RegConsoleCmd( "say", ReadyUnready, "", FCVAR_PLUGIN);
        //ServerCommand("mp_waitingforplayers_cancel 1"); //eventually I should find a nice place for this for soap dm; totally unimportant though
        HookEvent("player_changeclass",PlayerChangeClass,EventHookMode_Pre);

   //we need to stop players from switching teams (to the other or to spec) if the hasGameStarted - hook playerteam and return plugin handled if hasGameStarted

        HookEvent("tf_game_over",TFGameOver,EventHookMode_Pre); //this is called when a team reaches winlimit
        HookEvent("teamplay_game_over",TFGameOver,EventHookMode_Pre); //this is called when the time runs out (stalemate or win)
        countdownText = CreateHudSynchronizer();
        ServerCommand("mp_tournament 0");
        ServerCommand("mp_timelimit 0"); //so map never changes on its own

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

	//resets steamids, team, class, positions, class limits, game commands, and votes
	//warmup mod is just overridden and therefore doesn't need to be reset
	numberOfPlayersAddSteam=0;
	numberOfPlayersDropped=0;
	numberOfPlayersAddTeam=0;
	numberOfPlayersAddClass=0;
	numberOfPlayersAddPositions=0;
	numberOfClassLimit=1;
	votesToSub=0;
	votesToWait=0;
	waitingForPlayer=false;
	waitingForSubVote=false;
	canPause=false;
	gameCountdown = INVALID_HANDLE;

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

public Action:CommandKickAllNonwhitelist(client, args){ //should this include the pause bot? hm.. yes, it should, as long as the server isn't paused for some reason.
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
					if(!IsFakeClient(i)){ //I added this in for the pause bot, so it's not kicked
						KickClient(i, "You are not whitelisted for the new match" );
					}
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
	for(new i=1; i<MAXPLAYERS+1; i++){ //lets the players ready up, to start the new match
		playerReady[i]=false;
	}
	gameCountdown = INVALID_HANDLE;
	canPlayersReady=true;
	PrintToChatAll("\x04You may now type .ready and start the game.");
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
						PrintToChat(i,"\x04You are being moved to the red team");
					}else if(teamForPlayer[a]==3){
						PrintToChat(i,"\x04You are being moved to the blue team");
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
					PrintToChat(i,"\x04Your class is being changed to %s.",className);
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
        PrintToChatAll("\x04Match over!");
}

public Timer:EndTournamentGame(Handle:data){
        ServerCommand("mp_tournament 0");
        ServerCommand(warmupActivationCommands[activeWarmupMode][ENABLE]);
        PrintToChatAll("\x04Entering warmup mode.");
        ServerCommand("mp_timelimit 0"); //so map never changes on its own
        hasGameStarted=false;
}


//It appears I might need to have the same code for playerspawn and playerteam
//Bug: under same circumstances, the player's viewmodel is messed up. This is probably related to the above comment.
public Action:PlayerChangeClass(Handle:event, const String:name[], bool:dontBroadcast) {
//Bug: the text says "*You will respawn as [class]" immediately after "You cannot play [class]" when outside the spawn room' - we should block that message for aesthetics
	if(!IsClientConnected(GetClientOfUserId (GetEventInt(event, "userid"))) || !hasGameStarted || IsFakeClient(GetClientOfUserId (GetEventInt(event, "userid"))) ){
		return;
	}

	new userid = GetEventInt(event, "userid");
	new user = GetClientOfUserId (userid);
	new TFClassType: class = TFClassType:GetEventInt(event, "class");
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
				while(i<9 && positionsForPlayer[a][i]){
					canPlayClass[positionsForPlayer[a][i]]=true;
					i++;
				}
				if(class==TFClass_Scout){
					if(IsFull(team,1,class)){
						TF2_SetPlayerClass(user,oldClass,true,true); //should this section even include this function? why not nothing?
						PrintToChat(user,"\x04Your team cannot have any more scouts.");
					}
					if(!canPlayClass[1]){
						TF2_SetPlayerClass(user,oldClass,true,true); //third should be false if player died, maybe..
						PrintToChat(user,"\x04You cannot play scout.");
					}
				}else if(class==TFClass_Soldier){
					if(IsFull(team,2,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04Your team cannot have any more soldiers.");
					}
					if(!canPlayClass[2]){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04You cannot play soldier.");
					}
				}else if(class==TFClass_Pyro){
					if(IsFull(team,3,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04Your team cannot have any more pyros.");
					}
					if(!canPlayClass[3]){
						TF2_SetPlayerClass(user,oldClass,true,true); 
						PrintToChat(user,"\x04You cannot play pyro.");
					}
				}else if(class==TFClass_DemoMan){
					if(IsFull(team,4,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04Your team cannot have any more demomen.");
					}
					if(!canPlayClass[4]){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04You cannot play demoman.");
					}
				}else if(class==TFClass_Heavy){
					if(IsFull(team,5,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04Your team cannot have any more heavies.");
					}
					if(!canPlayClass[5]){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04You cannot play heavy.");
					}
				}else if(class==TFClass_Engineer){
					if(IsFull(team,6,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04Your team cannot have any more engineers.");
					}
					if(!canPlayClass[6]){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04You cannot play engineer.");
					}
				}else if(class==TFClass_Medic){
					if(IsFull(team,7,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04Your team cannot have any more medics.");
					}
					if(!canPlayClass[7]){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04You cannot play medic.");
					}
				}else if(class==TFClass_Sniper){
					if(IsFull(team,8,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04Your team cannot have any more snipers.");
					}
					if(!canPlayClass[8]){
						TF2_SetPlayerClass(user,oldClass,true,true); 
						PrintToChat(user,"\x04You cannot play sniper.");
					}
				}else if(class==TFClass_Spy){
					if(IsFull(team,9,class)){
						TF2_SetPlayerClass(user,oldClass,true,true);
						PrintToChat(user,"\x04Your team cannot have any more spies.");
					}
					if(!canPlayClass[9]){
						TF2_SetPlayerClass(user,oldClass,true,true); 
						PrintToChat(user,"\x04You cannot play spy.");
					}
				}
			}
		}
	}
}

public OnClientAuthorized( client, const String:auth[] ) {
	// Nightgunner had an if StrEqual( auth, "BOT" ) to not kick the SourceTV bot or the replay bot, but I think IsFakeClient covers those bots (all bots)
	if(IsFakeClient(client)){ //I added this in for the pause bot, so it's not kicked or seriously considered
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
			//to-do: move every droppedPlayerSteamID above this one down one index in the array

			//this whole sub feature only works with one player dropped at a time

			for(new i=1; i<MAXPLAYERS+1; i++){ //players haven't voted about a sub
				playerSubVote[i]=0;
			}
			decl String:playerName[MAX_NAME_LENGTH];
			GetClientName( client, playerName, MAX_NAME_LENGTH );
			LogMessage("Player %s has rejoined, no need for sub", playerName);
			PrintToChatAll("\x04Canceling sub vote. Game unpauses in 10 seconds.");

			countdownTime=10;
			CountdownDecrement(INVALID_HANDLE,2);

			CreateTimer(10.0,UnpauseGame); //10 seconds is the time for the rejoining player to get up to Sending Client Info
			votesToSub=0;
			votesToWait=0;
			waitingForPlayer=false;
			waitingForSubVote=false;
		}
	}


	

}

public OnClientDisconnect(client){
	if(!IsClientInGame(client) || IsFakeClient(client)){ //don't worry about a sub if the client is a bot or someone not in-game (a nonwhitelisted trying to connect but booted)
		return;
	}
	if(hasGameStarted && (GetClientTeam(client)==2 || GetClientTeam(client)==3)){//so specs don't count
		new String:playerName[32];
		GetClientName(client, playerName, sizeof(playerName));

		new String:currentSteamID[20];
		currentSteamID="";
		GetClientAuthString(client, currentSteamID,sizeof(currentSteamID));

		if(numberOfPlayersDropped<32){
			droppedPlayerSteamID[numberOfPlayersDropped]=currentSteamID;
			numberOfPlayersDropped++;
		}else{
			LogMessage("List of dropped players is full");
		}

		LogMessage("Pausing game because %s disconnected, steamid %s", playerName, currentSteamID);
		ServerCommand("sv_pausable 1"); //no bug here! I made canPause so nobody can pause the game except for the plugin (through a client, for one instant)
		CreateTimer(0.1,ClientPause);

		PrintToChatAll("\x04Type .sub to replace %s with a sub or .wait to wait 2 minutes for rejoin - 30 seconds to vote", playerName);
		Format(countdownTextString, sizeof(countdownTextString), "Match is paused.");	
		for (new i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i)){
				SetHudTextParams(-1.0, 0.4, 1000.0, 255, 255, 255, 255);
	//can I make 1000.0 into 0.0 for unlimited? can I make it 5.0 without ruining it?
				ShowSyncHudText(i,countdownText, countdownTextString)
			}
		}
		//even though players can only say one message to be displayed to everyone when the server pauses, all of their say commands are still processed by sm

		waitingForPlayer=true;
		waitingForSubVote=true;

		CreateTimer(30.0, EndSubVote);//30 seconds to vote - add currentSteamID with a datapack :(
	}
}

public Action:ClientPause(Handle:timer){
	new client=1;
	while (client<MaxClients && !IsClientInGame(client)){
		client++;
	}
	if(IsClientInGame(client)){
		canPause=true;
		FakeClientCommand(client,"pause"); //the client with the lowest index (first to join) is forced to enter the "pause" command - otherwise we'd need a bot, which was bleh
		canPause=false;
		ServerCommand("sv_pausable 0"); 
	}else{
		LogMessage("Nobody is on the server to enter the pause command - this is not good.");
	}
}

public Action:UnpauseGame(Handle:timer){
	ServerCommand("sv_pausable 1");
	CreateTimer(0.1,ClientPause);
	LogMessage("Unpausing game");
}

public Action:RevoteWait(Handle:timer){
	if(waitingForPlayer==false ||waitingForSubVote==false){
		return;
	}

	votesToSub=0;
	votesToWait=0;
	CreateTimer(30.0, EndSubVote);//30 seconds to vote - add currentSteamID with a datapack :(

	for(new i=1; i<MAXPLAYERS+1; i++){ //players haven't voted about a sub
		playerSubVote[i]=0;
	}
	PrintToChatAll("\x04Type .sub to replace with a sub or .wait to wait 2 minutes for rejoin - 30 seconds to vote");
}

public Action:EndSubVote(Handle:timer){ //should have steamid
	if(waitingForPlayer==false || waitingForSubVote==false){
		return;
	}

	if (votesToSub>= votesToWait) { //if there's a tie, call a sub
		//LogMessage("Requesting sub for %s", currentSteamID);
		LogMessage("Requesting sub");
		waitingForSubVote=false;
		PrintToChatAll("\x04Requesting sub %d-%d",votesToWait,votesToSub);
	}else{
		//LogMessage("Waiting 2 minutes to revote for %s", currentSteamID);
		LogMessage("Waiting 2 minutes to revote");
		
		CreateTimer(120.0,RevoteWait);

		PrintToChatAll("\x04Waiting 2 minutes to revote %d-%d",votesToSub,votesToWait);
	}
}

public OnClientPutInServer( client ) { //Nightgunner wrote this - does something with setting up MGE
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

public Action:ClientCommandPause(client,args){ //clients' "pause" command only works when sv_pausable is 1 *and* canPause is true, which it only is for one instant
	if(canPause==false){
		return Plugin_Handled;
	}else{
		return Plugin_Continue;
	}
}

public Action:ReadyUnready(client, args) { //should let this work in team chat too, I guess

//to-do: make this all pretty hud sync text

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
				PrintToChatAll("\x04Player %s is now ready.", playerName);
			}
			playerReady[client] = true;
		}			

		if (strcmp(text, ".notready") == 0 || strcmp(text, ".unready") == 0) {
			if(playerReady[client]==true){
				didSwitch=true;
				decl String:playerName[32];
				GetClientName(client, playerName, sizeof(playerName));
				PrintToChatAll("\x04Player %s is no longer ready.", playerName);
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
			new seconds = GAME_START_DELAY % 60;
			new minutes = GAME_START_DELAY / 60;
			PrintToChatAll("\x04%d players are now ready.", readyCount);
			if (minutes == 0) {
				PrintToChatAll("\x04Match starts in %d seconds.", seconds);
			} else if (seconds == 0) {
				PrintToChatAll("\x04Match starts in %d minutes.", minutes);
			} else {
				PrintToChatAll("\x04Match starts in %d minutes and %d seconds.", minutes, seconds);
			}
			if(gameCountdown==INVALID_HANDLE){
				gameCountdown = CreateTimer(float(GAME_START_DELAY), Timer:PubCompStartGame);
			}
		} else if (gameCountdown != INVALID_HANDLE) {
			KillTimer(gameCountdown);
			gameCountdown = INVALID_HANDLE;
			PrintToChatAll("\x04Down to %d ready player%s.  Countdown canceled.", readyCount, readyCount == 1 ? "" : "s");
		}else{
			PrintToChatAll("\x04%d players are now ready.", readyCount);
		}	

	//sub wait vote
	}else  if (strcmp(text, ".sub") == 0 || strcmp(text, ".wait") == 0){
		if(!hasGameStarted || !waitingForPlayer || !(GetClientTeam(client)==2 || GetClientTeam(client)==3) || !waitingForSubVote){
			return Plugin_Continue;
		}
		new bool:didSwitch=false;
		if (strcmp(text, ".sub") == 0) {
			if(playerSubVote[client]!=1){
				didSwitch=true;
				decl String:playerName[32];
				GetClientName(client, playerName, sizeof(playerName));
				PrintToChatAll("\x04Player %s has voted for a sub.", playerName);
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
				PrintToChatAll("\x04Player %s has voted to wait.", playerName);
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

public Action:OnGetGameDescription(String:gameDesc[64])
{
	Format(gameDesc, sizeof(gameDesc), "PubComp Match v%s",PLUGIN_VERSION);
	return Plugin_Changed;
}

public Timer:PubCompStartGame(Handle:data) {
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

public Action:CountdownDecrement(Handle:timer, any:idNumber){
	if(countdownTime>=1){
		CreateTimer(1.0,CountdownDecrement,idNumber);
		if(idNumber==1){
	//add if here for if countdownTime==1 then say second (not secondS)
			Format(countdownTextString, sizeof(countdownTextString), "Match starts in %d seconds", countdownTime );
		}else if(idNumber==2){ //the hud text does not show up if it is started when the game is paused (but it does continue into the pause, which I'm using)
	//add if here for if countdownTime==1 then say second (not secondS)
			Format(countdownTextString, sizeof(countdownTextString), "Match unpauses in %d seconds", countdownTime );
		}
		//the following is redundant but sometimes necessary the first time because players lose the message when they respawn
		for (new i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i)){
				SetHudTextParams(-1.0, 0.4, 1.0, 255, 255, 255, 255);
				ShowSyncHudText(i,countdownText, countdownTextString)
			}
		}
		countdownTime--;
	}else{
		countdownTime=0;
	}
}

public Timer:PubCompStartGame2(Handle:data) {
	PutPlayersOnClass();
	LogMessage("Setup classes. Game will start in %d seconds.", SETUP_CLASSES_TIME);
	PrintCenterTextAll("Setup Classes.");
	countdownTime=SETUP_CLASSES_TIME;
	CountdownDecrement(INVALID_HANDLE,1);

//should also stop players from switching teams - mp_teams_unbalance_limit or something
	ServerCommand("mp_restartgame %d", SETUP_CLASSES_TIME); //should say "Game is Live" now, not one second after.. why does esea do it with a delay? seems stupid.
	CreateTimer(float(SETUP_CLASSES_TIME) + 1.0, Timer:PubCompStartGame3); //I want this to be 0, but it doesn't show up at the right time! bleh, maybe that's why ^
}

public Timer:PubCompStartGame3(Handle:data) {
	ExecuteGameCommands();
	LogMessage("Match starting.")
	PrintCenterTextAll("----Game is LIVE----");
}