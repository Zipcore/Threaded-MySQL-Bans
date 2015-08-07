#include <sourcemod>
#include <sdktools>
#define PLUGIN_VERSION "1.3 (enhanced)"

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
	VerifyTable();
	StartSQL();
	CreateConVar("sm_mybans_version", PLUGIN_VERSION, "MYSQL-T Bans Version", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	AddCommandListener(OnAddBan, "sm_addban");
}

bool VerifyTable()
{
	char error[255];
	char query[512];

	Handle db = SQL_Connect("default", true, error, sizeof(error));
	if (db == null)
	{
		LogError("[MYBans] Couldn't connect to database! Error: %s", error);
		return false;
	}

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

	bool success = SQL_FastQuery(db, query);
	if(!success)
	{
			SQL_GetError(db, error, sizeof(error));
			LogError("[MYBans] Unable to verify mysql_bans table! Error: %s", query);
	}

	delete db;
	return true;
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
	else
		connection = database;
}

public void OnClientPostAdminCheck(int client)
{
	if(IsFakeClient(client))
		return;

	char steam_id[32];
	char query[255];

	GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id));

	int buffer_len = strlen(steam_id) * 2 + 1;
	char[] v_steam_id = new char[buffer_len];
	connection.Escape(steam_id, v_steam_id, buffer_len);

	Format(query, sizeof(query), "SELECT ban_length, ban_reason, (now()-timestamp)/60 FROM my_bans WHERE steam_id = '%s';", v_steam_id);
	connection.Query(ClientChecked, query, GetClientUserId(client));
}

public void ClientChecked(Database database, DBResultSet result, const char[] error, any data)
{
	int client;
	int ban_length;
	int ban_remaining;
	char steam_id[32];
	char ban_reason[100];
	char query[255];

	if ((client = GetClientOfUserId(data)) == 0)
		return;

	GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id));

	int buffer_len = strlen(steam_id) * 2 + 1;
	char[] v_steam_id = new char[buffer_len];
	connection.Escape(steam_id, v_steam_id, buffer_len);

	if (result == null)
	{
		LogError("[MYBans] Query failed! %s", error);
		KickClient(client, "Error: Reattempt connection");
	}

	if(!result.FetchRow())
		return;

	ban_length = result.FetchInt(0);
	result.FetchString(1, ban_reason, sizeof(ban_reason));

	if (ban_length == 0)
		ban_remaining = 0;
	else
		ban_remaining = ban_length - result.FetchInt(2);

	if (ban_length == 0 || ban_remaining > 0)
	{
		char duration_string[60];
		GetDurationString(duration_string, sizeof(duration_string), ban_remaining);
		KickClient(client, "Banned (%s): %s", duration_string, ban_reason);
	}
	else
	{
		Format(query, sizeof(query), "DELETE FROM my_bans WHERE steam_id='%s';", v_steam_id);
		connection.Query(ClientUnbanned, query);
		LogAction(0, 0, "Allowing %L to connect. Ban has expired.", client);
	}
}

void GetDurationString(char[] duration_string, int duration_string_size, int duration)
{
	if (duration == 0)
		strcopy(duration_string, duration_string_size, "permanently");
	else
		Format(duration_string, duration_string_size, "%d %s", duration, (duration == 1) ? "minute" : "minutes");
}

public void ClientUnbanned(Database database, DBResultSet result, const char[] error, any data)
{
	if (result == null)
		LogError("[MYBans] Query failed! %s", error);
}

public Action OnBanClient(int client, int time, int flags, const char[] reason, const char[] kick_message, const char[] command, any admin)
{
	char steam_id[32];
	char player_name[65];

	GetClientAuthId(client, AuthId_Steam2, steam_id, sizeof(steam_id));
	GetClientName(client, player_name, sizeof(player_name));

	MyBanClient(steam_id, player_name, time, reason, admin);

	char duration_string[60];
	GetDurationString(duration_string, sizeof(duration_string), time);

	KickClient(client, "Banned (%s): %s", duration_string, reason);
	LogAction(admin, client, "%L banned %L (%s): %s", admin, client, duration_string, reason);

	return Plugin_Continue;
}

public Action OnAddBan(int client, const char[] command, int argc)
{
	if (!CheckCommandAccess(client, "sm_addban", ADMFLAG_BAN))
		return Plugin_Handled;

	if (argc < 2)
	{
		PrintToChat(client, "[SM] Usage: %s <minutes|0> <#userid|name> [reason]", command);
		return Plugin_Handled;
	}

	char arguments[256];
	GetCmdArgString(arguments, sizeof(arguments));

	char time_string[10];
	int len = BreakString(arguments, time_string, sizeof(time_string));

	char steam_id[32];
	int next_len = BreakString(arguments[len], steam_id, sizeof(steam_id));
	if (next_len != -1)
		len += next_len;
	else
	{
		len = 0;
		arguments[0] = '\0';
	}

	char ban_reason[100];
	next_len = BreakString(arguments[len], ban_reason, sizeof(ban_reason));
	if (next_len != -1)
		len += next_len;
	else
	{
		len = 0;
		arguments[0] = '\0';
	}

	int time = StringToInt(time_string);

	char duration_string[60];
	GetDurationString(duration_string, sizeof(duration_string), time);

	MyBanClient(steam_id, "(sm_addban)", time, ban_reason, client);

	LogAction(client, 0, "%L banned Steam ID %s (%s): %s", client, steam_id, duration_string, ban_reason);
	ReplyToCommand(client, "[MYBans] Banned Steam ID %s (%s): %s", steam_id, duration_string, ban_reason);

	return Plugin_Continue;
}

void MyBanClient(const char[] steam_id, const char[] player_name, int time, const char[] reason, int admin)
{
	char query[255];
	char source[100];

	if(admin == 0)
		source = "Console";
	else
		GetClientName(admin, source, sizeof(source));

	int buffer_len = strlen(steam_id) * 2 + 1;
	char[] v_steam_id = new char[buffer_len];
	connection.Escape(steam_id, v_steam_id, buffer_len);

	buffer_len = strlen(reason) * 2 + 1;
	char[] v_reason = new char[buffer_len];
	connection.Escape(reason, v_reason, buffer_len);

	buffer_len = strlen(source) * 2 + 1;
	char[] v_source = new char[buffer_len];
	connection.Escape(source, v_source, buffer_len);

	buffer_len = strlen(player_name) * 2 + 1;
	char[] v_player_name = new char[buffer_len];
	connection.Escape(player_name, v_player_name, buffer_len);

	Format(query, sizeof(query), "REPLACE INTO my_bans (player_name, steam_id, ban_length, ban_reason, banned_by, timestamp) VALUES ('%s','%s','%d','%s','%s',CURRENT_TIMESTAMP);", v_player_name, v_steam_id, time, v_reason, v_source);
	connection.Query(ClientBanned, query);
}

public void ClientBanned(Database database, DBResultSet result, const char[] error, any data)
{
	if (result == null)
		LogError("[MYBans] Query failed! %s", error);
}

public Action OnRemoveBan(const char[] steam_id, int flags, const char[] command, any admin)
{
	char query[255];

	int buffer_len = strlen(steam_id) * 2 + 1;
	char[] v_steam_id = new char[buffer_len];
	connection.Escape(steam_id, v_steam_id, buffer_len);

	Format(query, sizeof(query), "DELETE FROM my_bans WHERE steam_id='%s';", v_steam_id);
	connection.Query(ClientUnbanned, query);

	ReplyToCommand(admin, "[MYBans] User %s has been unbanned", steam_id);
	LogAction(admin, 0, "%L unbanned Steam ID %s.", admin, steam_id);

	return Plugin_Continue;
}
