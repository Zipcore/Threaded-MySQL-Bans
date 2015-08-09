#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.3 (enhanced)"

#define MAX_QUERY_LENGTH 255
#define BIG_QUERY_LENGTH 512

#define MAX_REASON_LENGTH 128
#define MAX_AUTH_LENGTH 32
#define MAX_DURATION_LENGTH 32

public Plugin myinfo = {
	name = "[ANY] MySQL-T Bans",
	author = "senseless | enhanced by sneakret | modified by Shadow_Man",
	description = "Threaded SteamID based mysql bans.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?p=1759904"
};

Database connection = null;

public void OnPluginStart()
{
	CreateConVar("sm_mybans_version", PLUGIN_VERSION, "MYSQL-T Bans Version", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	AddCommandListener(OnAddBan, "sm_addban");

	StartSQL();
}

void StartSQL()
{
	if(SQL_CheckConfig("threaded-bans"))
		Database.Connect(ConnectedToDatabase, "threaded-bans");
	else
		Database.Connect(ConnectedToDatabase, "default");
}

public void ConnectedToDatabase(Database database, const char[] error, any data)
{
	if (database == null)
		LogError("[MYBans] Error during connection to database: %s", error);
	else {
		connection = database;
		CreateTableIfNotExists();
	}
}

void CreateTableIfNotExists()
{
	char query[BIG_QUERY_LENGTH];

	Format(query,sizeof(query), "%s%s%s%s%s%s%s%s%s%s%s",
		"CREATE TABLE IF NOT EXISTS `my_bans` (",
		"	`id` int(11) NOT NULL auto_increment,",
		"	`steam_id` varchar(32) NOT NULL,",
		"	`player_name` varchar(65) NOT NULL,",
		"	`ban_length` int(1) NOT NULL default '0',",
		"	`ban_reason` varchar(100) NOT NULL,",
		"	`banned_by` varchar(100) NOT NULL,",
		"	`timestamp` timestamp NOT NULL default '0000-00-00 00:00:00' on update CURRENT_TIMESTAMP,",
		"	PRIMARY KEY	(`id`),",
		"	UNIQUE KEY `steam_id` (`steam_id`)",
		") ENGINE=MyISAM DEFAULT CHARSET=utf8 AUTO_INCREMENT=1;"
	);

	connection.Query(DatabaseCreated, query);
}

public void DatabaseCreated(Database database, DBResultSet result, const char[] error, any data)
{
	if(result == null)
		LogError("[MYBans] Error during table creation: %s", error);
}

public void OnClientPostAdminCheck(int client)
{
	CheckBanStateOfClient(client);
}

void CheckBanStateOfClient(int client)
{
	if(IsFakeClient(client))
		return;

	char steamId[MAX_AUTH_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

	int steamIdLength = strlen(steamId) * 2 + 1;
	char[] escapedSteamId = new char[steamIdLength];
	connection.Escape(steamId, escapedSteamId, steamIdLength);

	char query[MAX_QUERY_LENGTH];
	Format(query, sizeof(query), "SELECT ban_length, (now()-timestamp)/60, ban_reason FROM my_bans WHERE steam_id = '%s';", escapedSteamId);

	connection.Query(BanStateOfClientChecked, query, client);
}

public void BanStateOfClientChecked(Database database, DBResultSet result, const char[] error, any data)
{
	int client = data;
	if(client <= 0)
		return;

	if(result == null || !result.FetchRow()) {
		LogError("[MYBans] Error during check of ban state for client %L: %s", client, error);
		KickClient(client, "Error: Reattempt connection");
	}

	int banLength = result.FetchInt(0);
	int minutesSinceBan = result.FetchInt(1);
	int timeRemaining = banLength - minutesSinceBan;

	if(banLength == 0 || timeRemaining > 0) {
		char durationAsString[MAX_DURATION_LENGTH];
		DurationAsString(durationAsString, sizeof(durationAsString), timeRemaining);

		char banReason[MAX_REASON_LENGTH];
		result.FetchString(2, banReason, sizeof(banReason));

		KickClient(client, "Banned (%s): %s", durationAsString, banReason);
	}
	else {
		char steamId[MAX_AUTH_LENGTH];
		GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

		RemoveBanOf(steamId);
		LogAction(0, 0, "Allowing %L to connect. Ban has expired.", client);
	}
}

void DurationAsString(char[] buffer, int maxLength, int duration)
{
	if(duration == 0)
		strcopy(buffer, maxLength, "permanently");
	else
		Format(buffer, maxLength, "%d %s", duration, (duration == 1) ? "minute" : "minutes");
}

void RemoveBanOf(const char[] steamId)
{
	int steamIdlength = strlen(steamId) * 2 + 1;
	char[] escapedSteamId = new char[steamIdlength];
	connection.Escape(steamId, escapedSteamId, steamIdlength);

	char query[MAX_QUERY_LENGTH];
	Format(query, sizeof(query), "DELETE FROM my_bans WHERE steam_id='%s';", escapedSteamId);

	connection.Query(ClientUnbanned, query);
}

public void ClientUnbanned(Database database, DBResultSet result, const char[] error, any data)
{
	if(result == null)
		LogError("[MYBans] Query failed! %s", error);
}

public Action OnBanClient(int client, int time, int flags, const char[] reason, const char[] kick_message, const char[] command, any admin)
{
	char steamId[MAX_AUTH_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

	char playerName[MAX_NAME_LENGTH];
	GetClientName(client, playerName, sizeof(playerName));

	AddBanFor(playerName, steamId, time, reason, admin);

	return Plugin_Continue;
}

public Action OnAddBan(int admin, const char[] command, int argc)
{
	if(!CheckCommandAccess(admin, "sm_addban", ADMFLAG_BAN))
		return Plugin_Handled;

	if(argc < 2) {
		PrintToChat(admin, "[SM] Usage: %s <minutes|0> <#userid|name> [reason]", command);
		return Plugin_Handled;
	}

	char arguments[256];
	GetCmdArgString(arguments, sizeof(arguments));

	char banLengthAsString[10];
	int nextArgumentPosition = BreakString(arguments, banLengthAsString, sizeof(banLengthAsString));

	int banLength = StringToInt(banLengthAsString);

	char steamId[MAX_AUTH_LENGTH];
	nextArgumentPosition = BreakString(arguments[nextArgumentPosition], steamId, sizeof(steamId));

	char reason[MAX_REASON_LENGTH];
	strcopy(arguments[nextArgumentPosition], sizeof(reason), reason);

	AddBanFor("", steamId, banLength, reason, admin);
	return Plugin_Continue;
}

void AddBanFor(const char[] playerName, const char[] steamId, int banLength, const char[] reason, int admin)
{
	int stringLength = strlen(playerName) * 2 + 1;
	char[] escapedPlayerName = new char[stringLength];
	connection.Escape(playerName, escapedPlayerName, stringLength);

	stringLength = strlen(steamId) * 2 + 1;
	char[] escapedSteamId = new char[stringLength];
	connection.Escape(steamId, escapedSteamId, stringLength);

	stringLength = strlen(reason) * 2 + 1;
	char[] escapedReason = new char[stringLength];
	connection.Escape(reason, escapedReason, stringLength);

	char adminName[MAX_NAME_LENGTH];
	if(admin == 0)
		adminName = "Console";
	else
		GetClientName(admin, adminName, sizeof(adminName));

	stringLength = strlen(adminName) * 2 + 1;
	char[] escapedAdminName = new char[stringLength];
	connection.Escape(adminName, escapedAdminName, stringLength);

	char query[MAX_QUERY_LENGTH];
	Format(query, sizeof(query), "REPLACE INTO my_bans (player_name, steam_id, ban_length, ban_reason, banned_by, timestamp) VALUES ('%s','%s','%d','%s','%s',CURRENT_TIMESTAMP);", escapedPlayerName, escapedSteamId, banLength, escapedReason, escapedAdminName);
	connection.Query(ClientBanned, query);

	char durationAsString[MAX_DURATION_LENGTH];
	DurationAsString(durationAsString, sizeof(durationAsString), banLength);

	LogAction(admin, 0, "%L banned Steam ID %s (%s): %s", admin, steamId, durationAsString, reason);
	ReplyToCommand(admin, "[MYBans] Banned Steam ID %s (%s): %s", steamId, durationAsString, reason);
}

public void ClientBanned(Database database, DBResultSet result, const char[] error, any data)
{
	if(result == null)
		LogError("[MYBans] Query failed! %s", error);
}

public Action OnRemoveBan(const char[] steamId, int flags, const char[] command, any admin)
{
	RemoveBanOf(steamId);

	ReplyToCommand(admin, "[MYBans] User %s has been unbanned", steamId);
	LogAction(admin, 0, "%L unbanned Steam ID %s.", admin, steamId);

	return Plugin_Continue;
}
