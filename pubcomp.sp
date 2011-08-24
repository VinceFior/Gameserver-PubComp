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

new numberOfPlayersAddSteam=0;// =0 unnecessary..
new numberOfPlayersNames=0;
new numberOfPlayersDropped=0;
new numberOfPlayersAddTeam=0;
new numberOfPlayersAddClass=0;
new numberOfPlayersAddPositions=0;
new numberOfClassLimit=1;

new String:steamIDforTeamsAndClasses[32][20];
new String:playerNames[32][MAX_NAME_LENGTH];
new String:droppedPlayerSteamID[32][20];
new teamForPlayer[32];
new classForPlayer[32];
new positionsForPlayer[32][9];
new classLimit[10];

new bool:hasGameStarted=false;
new bool:canPlayersReady=false;
new waitingForPlayer=0; //number of missing players - somewhat redundant with numberOfPlayersDropped
new bool:waitingForSubVote=false;//true when players can vote (the 30-second window)
new bool:canPause=false;
new bool:waitingToStartGame=false;
new bool:isPaused=false;
new bool:hasPlayerSaid[MAXPLAYERS+1]=false; //for talking when paused

new bool:playerReady[MAXPLAYERS+1];
new playerSubVote[MAXPLAYERS+1];
new Handle:gameCountdown = INVALID_HANDLE;
new Handle:showReadyHudTimer=INVALID_HANDLE;

new Handle:countdownText=INVALID_HANDLE;
new countdownTime=0;
new String:countdownTextString[256]; //the countdown messages can be at most 255 characters long. I've set this arbitrarily.
new Handle:readyText=INVALID_HANDLE;
new String:readyTextString[256];
new String:notReadiedPlayersString[256];
new String:readiedPlayersString[256];
new String:notConnectedPlayersString[256];

new votesToSub=0;
new votesToWait=0;

//[Nightgunner]
// These functions and globals are for setting, activating and
// deactivating the desired pre-game/pause warmup mode.
#define NUM_WARMUP_MODES 2
#define ENABLE 0
#define DISABLE 1
new String:warmupModes[NUM_WARMUP_MODES + 1][16] = {"NONE", "SOAP", "MGE"};
new activeWarmupMode;
new String:warmupActivationCommands[NUM_WARMUP_MODES + 1][2][MAX_COMMAND_LENGTH] = {
	{"", ""}, //can't go directly from soap to nothing without a map change because soap disables the control points [V]: I disagree, restartgame
	{"sm plugins load soap_tf2dm", "sm plugins unload soap_tf2dm"},
	{"sm plugins load mgemod", "sm plugins unload mgemod"}
};

new playersNeeded = 1; //server should set this; make a command or cvar

public OnPluginStart() {
	RegConsoleCmd("pubcomp_set_player_team", CommandSetPlayerTeam, "",FCVAR_PLUGIN); // 2 is red, 3 is blue
	RegConsoleCmd("pubcomp_set_player_class", CommandSetPlayerClass, "",FCVAR_PLUGIN); // 1 is scout, ... , 9 is spy
	RegConsoleCmd("pubcomp_set_player_positions", CommandSetPlayerPositions, "", FCVAR_PLUGIN); // 2-5-8 is soldier, heavy and sniper; include main class
	RegConsoleCmd("pubcomp_set_class_limit", CommandSetClassLimit, "",FCVAR_PLUGIN); //must be entered in order: scout, soldier, pyro, ... spy (total of 9 times)
	RegConsoleCmd("pubcomp_add_steamid", CommandAddSteamID, "", FCVAR_PLUGIN );//add steamid to the whitelist
	RegConsoleCmd("pubcomp_add_name",CommandAddName,"",FCVAR_PLUGIN);//add a player's name
	RegConsoleCmd("pubcomp_add_game_command", CommandAddGameCommand, "", FCVAR_PLUGIN);//add rcon command to be executed upon match start
	RegConsoleCmd("pubcomp_set_warmup_mod", CommandSetWarmupMod, "", FCVAR_PLUGIN);//set warmup mod (NONE, SOAP, or MGE)
	RegConsoleCmd("pubcomp_reset_game_setup", CommandResetGameSetup, "",FCVAR_PLUGIN);//resets steamids, team, class, positions, class limits, and game commands
	RegConsoleCmd("pubcomp_kick_all_nonwhitelist", CommandKickAllNonwhitelist, "", FCVAR_PLUGIN);//kick all players not on the whitelist
	RegConsoleCmd("pubcomp_let_players_ready", CommandLetPlayersReady, "",FCVAR_PLUGIN);//allows players to .ready up and start the game
	RegConsoleCmd("pubcomp_replace_steamid_sub", CommandReplaceSteamIDSub, "",FCVAR_PLUGIN);//replaces one whitelisted steamid with another (for sub)
	//I read from Yak's FAQ that it's better to use AddCommandListener than RegConsoleCmd.. I'm guessing that would only affect pause and/or say, and it's just a slight optimization. Meh.
	RegConsoleCmd("pause", ClientCommandPause, "",FCVAR_PLUGIN);//only let the pausebot pause
	RegConsoleCmd( "say", ReadyUnready, "", FCVAR_PLUGIN);//check when players say things for votes (starting game and calling sub)
	AddCommandListener(Command_JoinTeam, "jointeam");//only let players join the right team during a match
	HookEvent("player_changeclass",PlayerChangeClass,EventHookMode_Pre);//only let player change class to what he and his team is allowed
	HookEvent("tf_game_over",TFGameOver,EventHookMode_Pre); //this is called when a team reaches winlimit
	HookEvent("teamplay_game_over",TFGameOver,EventHookMode_Pre); //this is called when the match time (map time) runs out (stalemate or win)
	HookEvent( "teamplay_round_win", Event_RoundEnd); //called when a team wins a round (including stalemates)
	countdownText = CreateHudSynchronizer();
	readyText = CreateHudSynchronizer();

		//ServerCommand("mp_waitingforplayers_cancel 1"); //eventually I should find a nice place for this for soap dm; totally unimportant though

	ServerCommand("mp_tournament 0");//just in case
	ServerCommand("mp_timelimit 0"); //just in case

	ServerCommand("pubcomp_reset_game_setup"); //I'll rewrite this line so as to call the command internally.. /lazy
	//CommandResetGameSetup();
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
	numberOfPlayersNames=0;
	numberOfPlayersDropped=0;
	numberOfPlayersAddTeam=0;
	numberOfPlayersAddClass=0;
	numberOfPlayersAddPositions=0;
	numberOfClassLimit=1;
	for (new sayClient=1; sayClient<=MaxClients; sayClient++){
		hasPlayerSaid[sayClient]=false;
	}
	votesToSub=0;
	votesToWait=0;
	waitingForPlayer=0;
	waitingForSubVote=false;
	canPause=false;
	waitingToStartGame=false;
	readyTextString="";
	notReadiedPlayersString="";
	readiedPlayersString="";
	notConnectedPlayersString="";
	countdownTextString="";

	gameCountdown = INVALID_HANDLE;
	showReadyHudTimer=INVALID_HANDLE;

	for(new i=0; i<32; i++){
		steamIDforTeamsAndClasses[i][0]=0; //steamid
		droppedPlayerSteamID[i][0]=0; //list of dropped players
		playerNames[i][0]=0; //name
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
					if(!IsFakeClient(i)){ //bots are not kicked
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
	showReadyHudTimer=INVALID_HANDLE;
	gameCountdown = INVALID_HANDLE;
	canPlayersReady=true;
	hasGameStarted=false;
	waitingToStartGame=false;
	PrintToChatAll("\x04You may now type .ready and start the game.");

	UpdateReadyHud();

	return Plugin_Handled;
}


public UpdateReadyHud()
{
	if(showReadyHudTimer!=INVALID_HANDLE){
		KillTimer(showReadyHudTimer);
		showReadyHudTimer=INVALID_HANDLE;
	}//these updates may otherwise not show up for up to 1 second - I call ShowReadyHud and cancel the previous timer
	if(!hasGameStarted){
		ShowReadyHud(INVALID_HANDLE,1);
	}

	notReadiedPlayersString="";
	readiedPlayersString="";
	notConnectedPlayersString="";
	new String:playerName[MAX_NAME_LENGTH];
	for(new i=1; i<=MaxClients; i++){//this would also count specs.. I need to figure out how specs work into everything pre- and post- match
		if(IsClientInGame(i)){
			GetClientName( i, playerName, MAX_NAME_LENGTH );
			if(playerReady[i]==true){
				StrCat(readiedPlayersString,sizeof(readiedPlayersString),playerName);
				StrCat(readiedPlayersString,sizeof(readiedPlayersString),"\n  ");

			}else{
				StrCat(notReadiedPlayersString,sizeof(notReadiedPlayersString),playerName);
				StrCat(notReadiedPlayersString,sizeof(notReadiedPlayersString),"\n  ");
			}
		}
	}
	new String:currentSteamID[20]; //check for players who should be in game but are not
	for (new i=0; i<numberOfPlayersAddSteam; i++){
		new a=0;
		do{
			a++;
			if(IsClientConnected(a)){
				GetClientAuthString(a, currentSteamID,sizeof(currentSteamID));
			}else{
				currentSteamID="x";//not null
			}
		}while(a<MaxClients && !StrEqual(currentSteamID,steamIDforTeamsAndClasses[i]))
		if (a==MaxClients){//then client not found
			StrCat(notConnectedPlayersString,sizeof(notConnectedPlayersString),playerNames[i]);
			StrCat(notConnectedPlayersString,sizeof(notConnectedPlayersString),"\n  ");
		}	
	}
}



public Action:ShowReadyHud(Handle:timer, any:idNumber){
	if(idNumber==0){//0 is to clear the hud text
		if(showReadyHudTimer!=INVALID_HANDLE){
			KillTimer(showReadyHudTimer);
			showReadyHudTimer = INVALID_HANDLE;
		}
		for (new i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i)){
				Format(readyTextString, sizeof(readyTextString),"");
				SetHudTextParams(-1.0, -1.0, 0.0, 0, 0, 0, 0);
				ShowSyncHudText(i,readyText, readyTextString)
			}
		}
	}else if(idNumber==1){
		Format(readyTextString, sizeof(readyTextString),"Ready:\n  %s\nNot ready:\n  %s\nNot connected:\n  %s",readiedPlayersString,notReadiedPlayersString,notConnectedPlayersString);
		for (new i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i)){
				SetHudTextParams(0.1, 0.1, 1.0, 0, 255, 0, 255);
				ShowSyncHudText(i,readyText, readyTextString)
			}
		}
		showReadyHudTimer=CreateTimer(1.0,ShowReadyHud,1);
	}

}


public Action:CommandSetPlayerPositions(client,args){
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to set player positions.", client );
		return Plugin_Stop;
	}
	new String:classBuffer[9][2];
	new String:positionsBuffer[18]; // "1-2-3-4-5-6-7-8-9" = 17 + terminator
	GetCmdArg(1,positionsBuffer, sizeof(positionsBuffer ) );
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
	GetCmdArg(1,classBuffer,sizeof(classBuffer));
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
	GetCmdArg(1,teamBuffer, sizeof( teamBuffer ) );
	new teamNumber=StringToInt(teamBuffer);
	teamForPlayer[numberOfPlayersAddTeam]=teamNumber;
	numberOfPlayersAddTeam++;
	return Plugin_Handled;
}

public Action:CommandSetClassLimit(client,args){
	if(numberOfClassLimit>9){
		LogMessage("Cannot add a class limit for the %dth class (called too many times; reset limits first).",numberOfClassLimit);
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
						LogMessage("This player was not assigned a team: steamid is %s.",currentSteamID);
						return;
					} else if(teamForPlayer[a]==2){
						PrintToChat(i,"\x04You are being moved to the red team.");
					}else if(teamForPlayer[a]==3){
						PrintToChat(i,"\x04You are being moved to the blue team.");
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
							LogMessage("Player with steamid %s was not given a class.", currentSteamID);
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
						{	//(if player wasn't given a class, they can play pyro. sure. trololo) EDIT: this should never be called now that I have the -1 case
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

public Action:CommandAddName(client,args){
	if (client != 0) {
		LogMessage("Client %d is not permitted to add player names.", client);
		return Plugin_Stop;
	}
	new String:name[MAX_NAME_LENGTH];
	GetCmdArg(1,name,sizeof(name));

	if(numberOfPlayersNames>31){
		LogMessage("Failed to add %s to the list of player names. List is full.",name);
		return Plugin_Handled;
	}
	playerNames[numberOfPlayersNames]=name;
	numberOfPlayersNames++;
	LogMessage("Added %s to the list of player names.",name);
	return Plugin_Handled;
}

public Action:CommandAddSteamID( client, args ) {
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to add users to the whitelist.", client );
		return Plugin_Stop;
	}
	new String:id[20];
	GetCmdArg(1,id,sizeof(id));

	if(numberOfPlayersAddSteam>31){
		LogMessage( "Failed to add %s to the whitelist. Whitelist is full.", id );
		return Plugin_Handled;
	}
	steamIDforTeamsAndClasses[numberOfPlayersAddSteam]=id;
	numberOfPlayersAddSteam++;
	LogMessage( "Added %s to the whitelist.", id );
	return Plugin_Handled;
}

public Action:CommandReplaceSteamIDSub(client, args){
	if ( client != 0 ) {
		LogMessage( "Client %d is not permitted to replace users on the whitelist.", client );
		return Plugin_Stop;
	}
	new String:oldAndNewSteamids[2][20];
	GetCmdArg(1,oldAndNewSteamids[0],20);
	GetCmdArg(2,oldAndNewSteamids[1],20);
	new String:replacementName[MAX_NAME_LENGTH];
	GetCmdArg(3,replacementName,sizeof(replacementName));
	//new name is oldAndNewSteamids[2]
	//find where steamid is oldAndNewSteamids[0] and replace it with oldAndNewSteamids[1]
	new i=-1;
	do{
		i++;
	}while(i<numberOfPlayersAddSteam && !StrEqual(oldAndNewSteamids[0],steamIDforTeamsAndClasses[i]));

	new String:oldPlayerName[MAX_NAME_LENGTH];
	new String:newPlayerName[MAX_NAME_LENGTH];

	if(i==numberOfPlayersAddSteam){
		LogMessage("Cannot find player with steamid %s on the whitelist", oldAndNewSteamids[0]);
	}else{

		oldPlayerName=playerNames[i];
		playerNames[i]=replacementName;
		newPlayerName=playerNames[i];

		steamIDforTeamsAndClasses[i]=oldAndNewSteamids[1]
		LogMessage( "Replaced %s of steamid %s with %s of steamid %s on the whitelist",oldPlayerName,oldAndNewSteamids[0],newPlayerName,oldAndNewSteamids[1]);
	}

	i=-1;
	do{
		i++;
	}while(i<numberOfPlayersDropped && !StrEqual(oldAndNewSteamids[0],droppedPlayerSteamID[i]));

	if(i==numberOfPlayersDropped){
		LogMessage("Cannot find player with steamid %s on the dropped players list", oldAndNewSteamids[0]);
	}else{
		droppedPlayerSteamID[i]=oldAndNewSteamids[1];
		LogMessage( "Replaced %s of steamid %s with %s of steamid %s on the dropped players list",oldPlayerName,oldAndNewSteamids[0],newPlayerName,oldAndNewSteamids[1]);
		PrintToChatAll("\x04A sub, %s, is on the way for %s!",newPlayerName,oldPlayerName); //name
	}

	return Plugin_Handled;
}

public Action:Event_RoundEnd(Handle: event, const String:name[], bool:dontBroadcast){
//maybe to-do: if the game is now over, call TFGameOver and return? it doesn't look bad the way it currently is, and I don't want to have to manually check for match end
	new timeleft;
	new String:timeleftString[256];
	if(GetEventInt(event, "team")==2){
		GetMapTimeLeft(timeleft);
		Format(timeleftString, sizeof(timeleftString), "%d:%02d", (timeleft / 60), (timeleft % 60));
		PrintToChatAll("\x04Red team won the round, score is %d-%d. %s remaining.",GetTeamScore(2),GetTeamScore(3),timeleftString);
		LogMessage("\x04Red team won the round, score is %d-%d. %s remaining.",GetTeamScore(2),GetTeamScore(3),timeleftString);
	}else if(GetEventInt(event,"team")==3){
		GetMapTimeLeft(timeleft);
		Format(timeleftString, sizeof(timeleftString), "%d:%02d", (timeleft / 60), (timeleft % 60));
		PrintToChatAll("\x04Blue team won the round, score is %d-%d. %s remaining.",GetTeamScore(3),GetTeamScore(2),timeleftString);
		LogMessage("\x04Blue team won the round, score is %d-%d. %s remaining.",GetTeamScore(3),GetTeamScore(2),timeleftString);
	}
}

public Action:TFGameOver(Handle: event, const String:name[], bool:dontBroadcast){
	ServerCommand("mp_restartgame 1"); //restarting the game (in 1 second) stops it from needing tournament mode to not change maps - can I do this in less than one second?
	//small Bug: the scoreboard pops up and needs to be manually closed (hitting Tab once)
	CreateTimer(1.0, Timer:EndTournamentGame); //as soon as the game can have tournament off without changing maps, get rid of it - it is unnecessary and looks distracting
	if(GetTeamScore(3)>GetTeamScore(2)){
		LogMessage("Match over! Blue team wins %d-%d.",GetTeamScore(3),GetTeamScore(2))
		PrintToChatAll("\x04Match over! Blue team wins %d-%d.",GetTeamScore(3),GetTeamScore(2))
	}else if(GetTeamScore(2)>GetTeamScore(3)){
		LogMessage("Match over! Red team wins %d-%d.",GetTeamScore(2),GetTeamScore(3))
		PrintToChatAll("\x04Match over! Red team wins %d-%d.",GetTeamScore(2),GetTeamScore(3))
	}else{ //is this a reliable indicator of which team won? what about stopwatch?
		LogMessage("Match over! Tie at %d-%d, Blue-Red.",GetTeamScore(3),GetTeamScore(2))
		PrintToChatAll("\x04Match over! Tie at %d-%d, Blue-Red.",GetTeamScore(3),GetTeamScore(2))
	}
}

public Timer:EndTournamentGame(Handle:data){
	ServerCommand("mp_tournament 0");
	ServerCommand(warmupActivationCommands[activeWarmupMode][ENABLE]);
	PrintToChatAll("\x04Entering warmup mode.");
	ServerCommand("mp_timelimit 0"); //so map never changes on its own
	hasGameStarted=false;
}

public Action:Command_JoinTeam(client, const String:command[], args) 
{
	if (!hasGameStarted || IsFakeClient(client) || !IsClientConnected(client))
	{
		return Plugin_Continue;
	}else{
		new String:Arg[20];
		GetCmdArg(1, Arg, sizeof(Arg));
		new newTeam=0;
		//TF2 team 0 is "auto", 1 is "spectate", 2 is "red", 3 is "blue", as far as jointeam's argument (important)
		//TF2 team 0 is "Unassigned", 1 is "Spectator", 2 is "RED", 3 is "BLU", as far as it says in chat (unimportant)
		if(StrEqual(Arg, "auto",false )){
			newTeam=0;
		}else if(StrEqual(Arg, "spectate",false )){
			newTeam=1;
		}else if(StrEqual(Arg, "red",false )){
			newTeam=2;
		}else if(StrEqual(Arg, "blue",false )){
			newTeam=3;
		}
		new oldTeam=GetClientTeam(client)
		if(oldTeam==newTeam){//I don't think this can ever happen, but better safe than sorry
			return Plugin_Continue; //_Handled?
		}
		new String:currentSteamID[20];
		currentSteamID="";
		GetClientAuthString(client, currentSteamID,sizeof(currentSteamID));
		new i=-1;
		do{
			i++;
		}while(i<numberOfPlayersAddSteam && !StrEqual(currentSteamID,steamIDforTeamsAndClasses[i]))
		new shouldTeam=teamForPlayer[i];
		if(newTeam!=shouldTeam){
			ChangeClientTeam(client,shouldTeam);
			return Plugin_Handled;
		}
		return Plugin_Continue;
	}
}

public Action:PlayerChangeClass(Handle:event, const String:name[], bool:dontBroadcast) {

//I need to have the same code for playerspawn and playerteam
//Bug: under same circumstances, the player's viewmodel is messed up until the final restart. This is related to the above comment.
//TF2_SetPlayerClass(user,oldClass,true,true); //third should be false if player died, maybe..

//Bug: the text says "*You will respawn as [class]" immediately after "You cannot play [class]" when outside the spawn room' - we should block that message for aesthetics

	if(!IsClientConnected(GetClientOfUserId (GetEventInt(event, "userid"))) || !hasGameStarted || IsFakeClient(GetClientOfUserId (GetEventInt(event, "userid"))) ){
		return;
	}

	new userid = GetEventInt(event, "userid");
	new user = GetClientOfUserId (userid);
	new TFClassType: class = TFClassType:GetEventInt(event, "class");
	new TFClassType: oldClass = TF2_GetPlayerClass(user);
	new team = GetClientTeam(user);

	if (class == oldClass || class == TFClass_Unknown){ //probably never called
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
						TF2_SetPlayerClass(user,oldClass,true,true);
					//unfortunately, it seems setting the class to the old class is all I can do - this hook is apparently after the player has changed class, not before.
					//if I can find an event that's fired before - like jointeam instead of player_team - I might be able to do this without respawning the same class. join_class doesn't work
					//the only bad thing about this is that the player respawns as the same class in the spawn room; no real problem or anything.
						PrintToChat(user,"\x04Your team cannot have any more scouts.");
					}
					if(!canPlayClass[1]){
						TF2_SetPlayerClass(user,oldClass,true,true);
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

	//resumes the game if the player is on the dropped list
	new String:currentSteamID[20];
	currentSteamID="";
	GetClientAuthString(client, currentSteamID,sizeof(currentSteamID));
	new indexFoundAt=-1;
	for (new a=0; a<numberOfPlayersDropped; a++){
		if(StrEqual(droppedPlayerSteamID[a],currentSteamID)){
			droppedPlayerSteamID[a][0]=0;
			numberOfPlayersDropped--;
			waitingForPlayer--;
			indexFoundAt=a;
		}
	}
	//move every droppedPlayerSteamID above this one down one index in the array, so there's no empty spots in the array (so it's like X X [] [] [] instead of X [] X [] [])
	if(indexFoundAt!=-1){//if the player who's joining was on the dropped players list
		for (new a=indexFoundAt; a<numberOfPlayersDropped;a++){
			if(a==MaxClients-1){
				droppedPlayerSteamID[a][0]=0;
			}else{
				droppedPlayerSteamID[a]=droppedPlayerSteamID[a+1];
			}
		}
		new String:playerName[MAX_NAME_LENGTH];
		GetClientName( client, playerName, MAX_NAME_LENGTH );
		LogMessage("Player %s has rejoined, no need for sub", playerName);
		PrintToChatAll("\x04Canceling sub vote for %s.", playerName);
	}


	if(waitingForPlayer<=0 && hasGameStarted){
			for(new i=1; i<MAXPLAYERS+1; i++){ //players haven't voted about a sub
				playerSubVote[i]=0;
			}

			PrintToChatAll("\x04Game unpauses in 10 seconds.");
			countdownTime=10;
			CountdownDecrement(INVALID_HANDLE,2);
			//the hud text does not show up if it is started when the game is paused, but it does continue into the pause if started before, which I'm using
			CreateTimer(10.0,UnpauseGame); //10 seconds is the time for the rejoining player to get up to Sending Client Info
			votesToSub=0;
			votesToWait=0;
			waitingForSubVote=false;
	}	

}

public OnClientDisconnect_Post(client){
	if(!hasGameStarted){
		UpdateReadyHud();
	}
}


public OnClientDisconnect(client){
	if(!IsClientInGame(client) || IsFakeClient(client)){ //don't worry about a sub if the client is a bot or someone not in-game (a nonwhitelisted trying to connect but booted)
		return;
	}
	if(playerReady[client]==true && !hasGameStarted){//if a readied player leaves before the game starts, unready him
		playerReady[client]=false;
		decl String:playerName[32];
		GetClientName(client, playerName, sizeof(playerName));
		PrintToChatAll("\x04Player %s is no longer ready.", playerName);
		if(waitingToStartGame){ //cancel countdown if the game was in countdown
			waitingToStartGame=false;
			KillTimer(gameCountdown);
			gameCountdown = INVALID_HANDLE;
			CountdownDecrement(INVALID_HANDLE,0);
			Format(countdownTextString, sizeof(countdownTextString),"Countdown canceled");
			for (new i = 1; i <= MaxClients; i++) {
				if (IsClientInGame(i)){
					SetHudTextParams(-1.0, 0.4, 5.0, 255, 0, 0, 255); //r,g,b,a (red text)
					ShowSyncHudText(i,countdownText, countdownTextString)
				}
			}
			new readyCount = 0;
			for (new i = 0; i < MAXPLAYERS+1; i++) {
				readyCount += playerReady[i] ? 1 : 0;
			}
			PrintToChatAll("\x04Down to %d ready player%s. Countdown canceled.", readyCount, readyCount == 1 ? "" : "s");
		}

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

		if(isPaused==false){
			LogMessage("Pausing game because %s disconnected, steamid %s", playerName, currentSteamID);
			//unload antiflood if it's loaded
			ServerCommand("sv_pausable 1"); //no bug here! I made canPause so nobody can pause the game except for the plugin (through a client, for one instant)
			CreateTimer(0.1,ClientPause);
			isPaused=true;
			Format(countdownTextString, sizeof(countdownTextString), "- - Match is paused - -"); //colors! what color? reeeed? then resume is greeeeen?? :D	
			for (new i = 1; i <= MaxClients; i++) {
				if (IsClientInGame(i)){
					SetHudTextParams(-1.0, 0.4, 0.0, 0, 255, 255, 255); //0.0 was 1000.0.. maybe 0 works because it's frozen (doesn't work elsewhere)
					ShowSyncHudText(i,countdownText, countdownTextString)
				}
			}
			//even though players can only say one message to be displayed to everyone when the server pauses, all of their say commands are still processed by SM
			//to-do: make a chat override that makes it look like players' messages are getting through to everyone else when they really aren't (PrintToChatAll what they say)

		}else{
			LogMessage("Keeping game paused because %s disconnected, steamid %s", playerName, currentSteamID);

		}
		PrintToChatAll("\x04Type .sub to replace %s with a sub or .wait to wait 2 minutes for rejoin - 30 seconds to vote", playerName);

		waitingForPlayer++;
		waitingForSubVote=true;

		//find the player's "index" in my arrays
		currentSteamID="";
		GetClientAuthString(client, currentSteamID,sizeof(currentSteamID));
		new index=-1;
		do{
			index++;
		}while(index<numberOfPlayersAddSteam && !StrEqual(currentSteamID,steamIDforTeamsAndClasses[index]))

		CreateTimer(30.0, EndSubVote,index);//i is the player's index in my arrays (numberOfPlayersAddSteam etc.)

	}
}

public Action:RevoteWait(Handle:timer, any:index){
	if(waitingForPlayer==0){
		return;
	}
	waitingForSubVote=true;
	votesToSub=0;
	votesToWait=0;

	CreateTimer(30.0, EndSubVote,index); //i is the player's index in my weird array system

	for(new i=1; i<MAXPLAYERS+1; i++){ //players haven't voted about a sub
		playerSubVote[i]=0;
	}
	PrintToChatAll("\x04Type .sub to replace %s with a sub or .wait to wait 2 minutes for rejoin - 30 seconds to vote",playerNames[index]);

}

public Action:EndSubVote(Handle:timer, any:index){
	if(waitingForPlayer==0){
		return;
	}

	if (votesToSub>votesToWait) {

		new String:currentSteamID[20];	
		currentSteamID=steamIDforTeamsAndClasses[index]

		LogMessage("Requesting sub for %s", currentSteamID);

		PrintToChatAll("\x04Requesting sub for %s, %d-%d",playerNames[index],votesToSub,votesToWait);//print name
	}else{ //if there's a tie, wait
		LogMessage("Waiting 2 minutes to revote for steamid %s", playerNames[index]);
		CreateTimer(120.0,RevoteWait,index);
		PrintToChatAll("\x04Waiting 2 minutes to revote for %s, %d-%d",playerNames[index],votesToSub,votesToWait);
	}
	waitingForSubVote=false;
}

public Action:ClientPause(Handle:timer){
	new client=1;
	while (client<MaxClients && !IsClientInGame(client)){
		client++;
	}
	if(IsClientInGame(client)){ // && is not the last client - don't pause if we can't unpause (though we could alternatively make a bot to unpause.. hm)
		canPause=true;
		FakeClientCommand(client,"pause"); //the client with the lowest index (first to join) is forced to enter the "pause" command - otherwise we'd need a bot, which was bleh
		canPause=false;
		ServerCommand("sv_pausable 0"); 
		for (new sayClient=1; sayClient<=MaxClients; sayClient++){
			hasPlayerSaid[sayClient]=false;
		}
	}else{
		LogMessage("Nobody is on the server to enter the pause command - this is not good.");
	}
}

public Action:UnpauseGame(Handle:timer){
	if(isPaused==true){
		ServerCommand("sv_pausable 1");
		CreateTimer(0.1,ClientPause);
		LogMessage("Unpausing game");
		isPaused=false;
	}else{
		LogMessage("Will not unpause the game, it is already paused.");
	}
}

public OnClientPutInServer( client ) { //Nightgunner wrote this - does something with setting up MGE
	decl String:map[PLATFORM_MAX_PATH];
	GetCurrentMap( map, PLATFORM_MAX_PATH );
	if ( StrEqual( map, "mge_training_v7" ) ) {
		FakeClientCommand( client, "say /first" );
	}
	UpdateReadyHud();//I added this
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
	decl String:text[192];
	GetCmdArg(1, text, sizeof(text));

	//pretend players are talking when the game is paused
	new String:playerNameForSay[MAX_NAME_LENGTH];
	GetClientName(client,playerNameForSay,sizeof(playerNameForSay));
	if(hasPlayerSaid[client]==true && isPaused){
		PrintToChatAll("%s :  %s",playerNameForSay,text);
	}else if (isPaused){
		hasPlayerSaid[client]=true; //make this an array for clients
	}

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
			UpdateReadyHud();
		}			

		if (strcmp(text, ".notready") == 0 || strcmp(text, ".unready") == 0) {
			if(playerReady[client]==true){
				didSwitch=true;
				decl String:playerName[32];
				GetClientName(client, playerName, sizeof(playerName));
				PrintToChatAll("\x04Player %s is no longer ready.", playerName);
			}
			playerReady[client] = false;
			UpdateReadyHud();
		}		

		if(didSwitch==false){
			return Plugin_Continue; //if the player's just being silly, don't reset the timer or restate that players are ready
		}

		new readyCount = 0;
		for (new i = 0; i < MAXPLAYERS+1; i++) {
			readyCount += playerReady[i] ? 1 : 0;
		}
		if (readyCount >= playersNeeded) {
			if(readyCount==1){
				PrintToChatAll("\x04%d player of %d is now ready.", readyCount, playersNeeded);
			}else{
				PrintToChatAll("\x04%d players of %d are now ready.", readyCount, playersNeeded);
			}
			if(waitingToStartGame==false){//same thing as if gameCountdown==invalid handle
				new seconds = GAME_START_DELAY % 60;
				new minutes = GAME_START_DELAY / 60;
				if (minutes == 0) {
					PrintToChatAll("\x04Class setup starts in %d seconds.", seconds);
				} else if (seconds == 0) {
					PrintToChatAll("\x04Class setup starts in %d minutes", minutes);
				} else {
					PrintToChatAll("\x04Class setup starts in %d minutes and %d seconds.", minutes, seconds);
				}
				countdownTime=10;
				CountdownDecrement(INVALID_HANDLE,3);
				if(gameCountdown==INVALID_HANDLE){
					waitingToStartGame=true;
					gameCountdown = CreateTimer(float(GAME_START_DELAY), Timer:PubCompStartGame);
				}
			}
		} else if (gameCountdown != INVALID_HANDLE) {
			waitingToStartGame=false;
			KillTimer(gameCountdown);
			gameCountdown = INVALID_HANDLE;
			CountdownDecrement(INVALID_HANDLE,0);
			Format(countdownTextString, sizeof(countdownTextString),"Countdown canceled");
			for (new i = 1; i <= MaxClients; i++) {
				if (IsClientInGame(i)){
					SetHudTextParams(-1.0, 0.4, 5.0, 255, 0, 0, 255); //r,g,b,a (red)
					ShowSyncHudText(i,countdownText, countdownTextString)
				}
			}
			PrintToChatAll("\x04Down to %d ready player%s. Countdown canceled.", readyCount, readyCount == 1 ? "" : "s");//Nightgunner, why? :o
		}else{
			if(readyCount==1){
				PrintToChatAll("\x04%d player of %d is now ready.", readyCount, playersNeeded);
			}else{
				PrintToChatAll("\x04%d players of %d are now ready.", readyCount, playersNeeded);
			}
		}	

	//sub wait vote
	}else  if (strcmp(text, ".sub") == 0 || strcmp(text, ".wait") == 0){
		if(!hasGameStarted || waitingForPlayer==0 || !(GetClientTeam(client)==2 || GetClientTeam(client)==3) || !waitingForSubVote){
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

public Action:CountdownDecrement(Handle:timer, any:idNumber){
	if(idNumber==0){//0 is to clear the hud text
		//Format(countdownTextString, sizeof(countdownTextString),"");//unnecessary with the following sethudtextparams
		countdownTime=0;
		for (new i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i)){
				SetHudTextParams(-1.0, 0.4, 1.0, 0, 0, 0, 0);
				ShowSyncHudText(i,countdownText, countdownTextString)
			}
		}
	}
	if(countdownTime>=1){
		CreateTimer(1.0,CountdownDecrement,idNumber);
		if(idNumber==1){
			if(countdownTime==1){
				Format(countdownTextString, sizeof(countdownTextString),"Match starts in 1 second");	
			}else{
				Format(countdownTextString, sizeof(countdownTextString),"Match starts in %d seconds",countdownTime );
			}
		}else if(idNumber==2){
			if(countdownTime==1){
				Format(countdownTextString, sizeof(countdownTextString),"Match unpauses in 1 second");
			}else{
				Format(countdownTextString, sizeof(countdownTextString),"Match unpauses in %d seconds",countdownTime );
			}
		}else if(idNumber==3){
			if(countdownTime==1){
				Format(countdownTextString, sizeof(countdownTextString),"Class setup starts in 1 second");
			}else{
				Format(countdownTextString, sizeof(countdownTextString),"Class setup starts in %d seconds",countdownTime );
			}
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

public Timer:PubCompStartGame(Handle:data) {
	ServerCommand(warmupActivationCommands[activeWarmupMode][DISABLE]);
	waitingToStartGame=false;
	hasGameStarted=true;
	canPlayersReady=false;
	for(new i=1; i<MAXPLAYERS+1; i++){
		playerReady[i]=false;
	}
	ShowReadyHud(INVALID_HANDLE,0);
	PutPlayersOnTeam();
	ServerCommand("mp_restartgame 1");
	CreateTimer(1.0, Timer:PubCompStartGame2);
}


public Timer:PubCompStartGame2(Handle:data) {
	PutPlayersOnClass();
	LogMessage("Setup classes. Game will start in %d seconds.", SETUP_CLASSES_TIME);
	PrintCenterTextAll("Set up classes now");
	countdownTime=SETUP_CLASSES_TIME;
	CountdownDecrement(INVALID_HANDLE,1);
	ServerCommand("mp_restartgame %d", SETUP_CLASSES_TIME); //should say "Game is Live" now, not one second after.. why does esea do it with a delay? seems stupid.
	CreateTimer(float(SETUP_CLASSES_TIME) + 1.0, Timer:PubCompStartGame3); //I want this to be 0, but it doesn't show up at the right time! bleh, maybe that's why ^
	//try setting a variable like "shouldShowHudText" to true here, and then hook player respawn to redrawing the countdown text if the variable is true
}

public Timer:PubCompStartGame3(Handle:data) {
	ServerCommand("mp_tournament 1");
	ExecuteGameCommands();
	LogMessage("Match starting.")
	Format(countdownTextString, sizeof(countdownTextString),"--- Match is LIVE ---");
	for (new i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i)){
			SetHudTextParams(-1.0, 0.4, 3.0, 0, 255, 0, 255); //r,g,b,a (green text)
			ShowSyncHudText(i,countdownText, countdownTextString)
		}
	}
}