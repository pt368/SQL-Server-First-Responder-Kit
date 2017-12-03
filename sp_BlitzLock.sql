IF OBJECT_ID('dbo.sp_BlitzLock') IS NULL
  EXEC ('CREATE PROCEDURE dbo.sp_BlitzLock AS RETURN 0;');
GO

ALTER PROCEDURE dbo.sp_BlitzLock
(
    @Top INT = 2147483647, 
	@DatabaseName NVARCHAR(256) = NULL,
	@StartDate DATETIME = '19000101', 
	@EndDate DATETIME = '99991231', 
	@ObjectName NVARCHAR(1000) = NULL,
	@StoredProcName NVARCHAR(256) = NULL,
	@AppName NVARCHAR(256) = NULL,
	@HostName NVARCHAR(256) = NULL,
	@LoginName NVARCHAR(256) = NULL,
	@EventSessionPath VARCHAR(256) = 'system_health*.xel', 
	@Debug BIT = 0, 
	@Help BIT = 0,
	@VersionDate DATETIME = NULL OUTPUT
)
AS
BEGIN

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
DECLARE @Version VARCHAR(30);
SET @Version = '1.0';
SET @VersionDate = '20171201';


	IF @Help = 1 PRINT '
	/*
	sp_BlitzLock from http://FirstResponderKit.org
	
	This script checks for and analyzes deadlocks from the system health session or a custom extended event path

	Variables you can use:
		@Top: Use if you want to limit the number of deadlocks to return.
			  This is ordered by event date ascending

		@DatabaseName: If you want to filter to a specific database

		@StartDate: The date you want to start searching on.

		@EndDate: The date you want to stop searching on.

		@ObjectName: If you want to filter to a specific able. 
					 The object name has to be fully qualified ''Database.Schema.Table''

		@StoredProcName: If you want to search for a single stored proc
		
		@AppName: If you want to filter to a specific application
		
		@HostName: If you want to filter to a specific host
		
		@LoginName: If you want to filter to a specific login

		@EventSessionPath: If you want to point this at an XE session rather than the system health session.
	
	
	
	To learn more, visit http://FirstResponderKit.org where you can download new
	versions for free, watch training videos on how it works, get more info on
	the findings, contribute your own code, and more.

	Unknown limitations of this version:
	 - None.  (If we knew them, they would be known. Duh.)

     Changes - for the full list of improvements and fixes in this version, see:
     https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/


	Parameter explanations:
		HOLD YOUR HORSES

    MIT License
	   
	All other copyright for sp_BlitzLock are held by Brent Ozar Unlimited, 2017.

	Copyright (c) 2017 Brent Ozar Unlimited

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.

	*/';


        DECLARE @ProductVersion NVARCHAR(128);
        DECLARE @ProductVersionMajor FLOAT;
        DECLARE @ProductVersionMinor INT;

        SET @ProductVersion = CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128));

        SELECT @ProductVersionMajor = SUBSTRING(@ProductVersion, 1, CHARINDEX('.', @ProductVersion) + 1),
               @ProductVersionMinor = PARSENAME(CONVERT(VARCHAR(32), @ProductVersion), 2);


        IF @ProductVersionMajor < 11.0
            BEGIN
                RAISERROR(
                    'sp_BlitzLock will throw a bunch of angry errors on versions of SQL Server earlier than 2012.',
                    0,
                    1) WITH NOWAIT;
                RETURN;
            END;

		IF @Top IS NULL
			SET @Top = 2147483647;

		IF @StartDate IS NULL
			SET @StartDate = '19000101';

		IF @EndDate IS NULL
			SET @EndDate = '99991231';
		

        IF OBJECT_ID('tempdb..#deadlock_data') IS NOT NULL
            DROP TABLE #deadlock_data;

        IF OBJECT_ID('tempdb..#deadlock_process') IS NOT NULL
            DROP TABLE #deadlock_process;

        IF OBJECT_ID('tempdb..#deadlock_stack') IS NOT NULL
            DROP TABLE #deadlock_stack;

        IF OBJECT_ID('tempdb..#deadlock_resource') IS NOT NULL
            DROP TABLE #deadlock_resource;

        IF OBJECT_ID('tempdb..#deadlock_owner_waiter') IS NOT NULL
            DROP TABLE #deadlock_owner_waiter;

        IF OBJECT_ID('tempdb..#deadlock_findings') IS NOT NULL
            DROP TABLE #deadlock_findings;

		CREATE TABLE #deadlock_findings
		(
		    id INT IDENTITY(1, 1) PRIMARY KEY CLUSTERED,
		    check_id INT NOT NULL,
			database_name NVARCHAR(256),
			object_name NVARCHAR(1000),
			finding_group NVARCHAR(100),
			finding NVARCHAR(4000)
		);


		/*Grab the initial set of XML to parse*/
        WITH xml
        AS ( SELECT CONVERT(XML, event_data) AS deadlock_xml
             FROM   sys.fn_xe_file_target_read_file(@EventSessionPath, NULL, NULL, NULL) )
        SELECT TOP ( @Top ) xml.deadlock_xml
        INTO   #deadlock_data
        FROM   xml
        WHERE  xml.deadlock_xml.value('(/event/@name)[1]', 'VARCHAR(256)') = 'xml_deadlock_report'
               AND xml.deadlock_xml.value('(/event/@timestamp)[1]', 'datetime') >= @StartDate
               AND xml.deadlock_xml.value('(/event/@timestamp)[1]', 'datetime') < @EndDate
			   ORDER BY xml.deadlock_xml.value('(/event/@timestamp)[1]', 'datetime')
			   OPTION ( RECOMPILE );

			   /*Eject early if we don't find anything*/
			   IF @@ROWCOUNT = 0
				BEGIN
					SELECT  N'WOO-HOO! We couldn''t find any deadlocks for '
							+ CONVERT(NVARCHAR(30), @StartDate)
							+ ' through '
							+ CONVERT(NVARCHAR(30), @EndDate)
							+ '!'
							AS [Noice], 
							N'sp_BlitzLock'AS [Proc Name], 
							N'SQL Server First Responder Kit' AS [FRK], 
							N'http://FirstResponderKit.org/' AS [URL], 
							N'To get help or add your own contributions, join us at http://FirstResponderKit.org.' AS [Info];
				RETURN;
				END;


		

		/*Parse process and input buffer XML*/
        SELECT      dd.deadlock_xml.value('(event/@timestamp)[1]', 'DATETIME2') AS event_date,
					dd.deadlock_xml.value('(//deadlock/victim-list/victimProcess/@id)[1]', 'NVARCHAR(256)') AS victim_id,
					ca.dp.value('@id', 'NVARCHAR(256)') AS id,
                    ca.dp.value('@currentdb', 'BIGINT') AS database_id,
                    ca.dp.value('@logused', 'BIGINT') AS log_used,
                    ca.dp.value('@waitresource', 'NVARCHAR(256)') AS wait_resource,
                    ca.dp.value('@waittime', 'BIGINT') AS wait_time,
                    ca.dp.value('@transactionname', 'NVARCHAR(256)') AS transaction_name,
                    ca.dp.value('@lasttranstarted', 'DATETIME2(7)') AS last_tran_started,
                    ca.dp.value('@lastbatchstarted', 'DATETIME2(7)') AS last_batch_started,
                    ca.dp.value('@lastbatchcompleted', 'DATETIME2(7)') AS last_batch_completed,
                    ca.dp.value('@lockMode', 'NVARCHAR(256)') AS lock_mode,
                    ca.dp.value('@trancount', 'BIGINT') AS transaction_count,
                    ca.dp.value('@clientapp', 'NVARCHAR(256)') AS client_app,
                    ca.dp.value('@hostname', 'NVARCHAR(256)') AS host_name,
                    ca.dp.value('@loginname', 'NVARCHAR(256)') AS login_name,
                    ca.dp.value('@isolationlevel', 'NVARCHAR(256)') AS isolation_level,
                    ca2.ib.query('.') AS input_buffer,
                    ca.dp.query('.') AS process_xml
        INTO        #deadlock_process
        FROM        #deadlock_data AS dd
        CROSS APPLY dd.deadlock_xml.nodes('//deadlock/process-list/process') AS ca(dp)
        CROSS APPLY dd.deadlock_xml.nodes('//deadlock/process-list/process/inputbuf') AS ca2(ib)
		WHERE (ca.dp.value('@currentdb', 'BIGINT') = DB_ID(@DatabaseName) OR @DatabaseName IS NULL)
		AND   (ca.dp.value('@clientapp', 'NVARCHAR(256)') = @AppName OR @AppName IS NULL)
		AND   (ca.dp.value('@hostname', 'NVARCHAR(256)') = @HostName OR @HostName IS NULL)
		AND   (ca.dp.value('@loginname', 'NVARCHAR(256)') = @LoginName OR @LoginName IS NULL)
		OPTION ( RECOMPILE );

			   
			   /*Eject early if we don't find anything*/
			   IF @@ROWCOUNT = 0
				BEGIN
					SELECT  N'WOO-HOO! We couldn''t find any deadlocks for '
								+ CASE WHEN @DatabaseName IS NOT NULL THEN 'Database:' + QUOTENAME(@DatabaseName) + ' ' ELSE '' END
								+ CASE WHEN @AppName IS NOT NULL THEN 'Application:' + QUOTENAME(@AppName) + ' ' ELSE '' END
								+ CASE WHEN @HostName IS NOT NULL THEN 'Host:' + QUOTENAME(@HostName) + ' ' ELSE '' END
								+ CASE WHEN @LoginName IS NOT NULL THEN 'Login:' + QUOTENAME(@LoginName) + ' ' ELSE '' END
							+ '!' AS [Noice], 
							N'sp_BlitzLock'AS [Proc Name], 
							N'SQL Server First Responder Kit' AS [FRK], 
							N'http://FirstResponderKit.org/' AS [URL], 
							N'To get help or add your own contributions, join us at http://FirstResponderKit.org.' AS [Info];
				RETURN;
				END;



		/*Parse execution stack XML*/
        SELECT      dp.id,
                    ca.dp.value('@procname', 'NVARCHAR(1000)') AS proc_name,
                    ca.dp.value('@sqlhandle', 'NVARCHAR(128)') AS sql_handle
        INTO        #deadlock_stack
        FROM        #deadlock_process AS dp
        CROSS APPLY dp.process_xml.nodes('//executionStack/frame') AS ca(dp)
		WHERE (ca.dp.value('@procname', 'NVARCHAR(256)') = @StoredProcName OR @StoredProcName IS NULL)
		OPTION ( RECOMPILE );

			   /*Eject early if we don't find anything*/
			   IF @@ROWCOUNT = 0
				BEGIN
					SELECT  N'WOO-HOO! We couldn''t find any deadlocks for ' + QUOTENAME(@StoredProcName) + '!'
							AS [Noice], 
							N'sp_BlitzLock'AS [Proc Name], 
							N'SQL Server First Responder Kit' AS [FRK], 
							N'http://FirstResponderKit.org/' AS [URL], 
							N'To get help or add your own contributions, join us at http://FirstResponderKit.org.' AS [Info];
				RETURN;
				END;


		/*Grab the full resource list*/
        SELECT      ca.dp.query('.') AS resource_xml
        INTO        #deadlock_resource
        FROM        #deadlock_data AS dd
        CROSS APPLY dd.deadlock_xml.nodes('//deadlock/resource-list') AS ca(dp)
		OPTION ( RECOMPILE );


		/*This parses object locks*/
        SELECT      ca.dr.value('@dbid', 'BIGINT') AS database_id,
                    ca.dr.value('@objectname', 'NVARCHAR(1000)') AS object_name,
                    ca.dr.value('@mode', 'NVARCHAR(256)') AS lock_mode,
                    w.l.value('@id', 'NVARCHAR(256)') AS waiter_id,
                    w.l.value('@mode', 'NVARCHAR(256)') AS waiter_mode,
                    o.l.value('@id', 'NVARCHAR(256)') AS owner_id,
                    o.l.value('@mode', 'NVARCHAR(256)') AS owner_mode
        INTO        #deadlock_owner_waiter
        FROM        #deadlock_resource AS dr
        CROSS APPLY dr.resource_xml.nodes('//resource-list/objectlock') AS ca(dr)
        CROSS APPLY ca.dr.nodes('//waiter-list/waiter') AS w(l)
        CROSS APPLY ca.dr.nodes('//owner-list/owner') AS o(l)
		WHERE (ca.dr.value('@objectname', 'NVARCHAR(1000)') = @ObjectName OR @ObjectName IS NULL)
		OPTION ( RECOMPILE );

			   /*Eject early if we don't find anything*/
			   IF @@ROWCOUNT = 0
				BEGIN
					SELECT  N'WOO-HOO! We couldn''t find any deadlocks for ' + @ObjectName + '!'
							AS [Noice], 
							N'sp_BlitzLock'AS [Proc Name], 
							N'SQL Server First Responder Kit' AS [FRK], 
							N'http://FirstResponderKit.org/' AS [URL], 
							N'To get help or add your own contributions, join us at http://FirstResponderKit.org.' AS [Info];
				RETURN;
				END;


		/*This parses page locks*/
        INSERT #deadlock_owner_waiter
        SELECT      ca.dr.value('@dbid', 'BIGINT') AS database_id,
                    ca.dr.value('@objectname', 'NVARCHAR(256)') AS object_name,
                    ca.dr.value('@mode', 'NVARCHAR(256)') AS lock_mode,
                    w.l.value('@id', 'NVARCHAR(256)') AS waiter_id,
                    w.l.value('@mode', 'NVARCHAR(256)') AS waiter_mode,
                    o.l.value('@id', 'NVARCHAR(256)') AS owner_id,
                    o.l.value('@mode', 'NVARCHAR(256)') AS owner_mode
        FROM        #deadlock_resource AS dr
        CROSS APPLY dr.resource_xml.nodes('//resource-list/pagelock') AS ca(dr)
        CROSS APPLY ca.dr.nodes('//waiter-list/waiter') AS w(l)
        CROSS APPLY ca.dr.nodes('//owner-list/owner') AS o(l)
		OPTION ( RECOMPILE );


		/*This parses key locks*/
        INSERT #deadlock_owner_waiter
        SELECT      ca.dr.value('@dbid', 'BIGINT') AS database_id,
                    ca.dr.value('@objectname', 'NVARCHAR(256)') AS object_name,
                    ca.dr.value('@mode', 'NVARCHAR(256)') AS lock_mode,
                    w.l.value('@id', 'NVARCHAR(256)') AS waiter_id,
                    w.l.value('@mode', 'NVARCHAR(256)') AS waiter_mode,
                    o.l.value('@id', 'NVARCHAR(256)') AS owner_id,
                    o.l.value('@mode', 'NVARCHAR(256)') AS owner_mode
        FROM        #deadlock_resource AS dr
        CROSS APPLY dr.resource_xml.nodes('//resource-list/keylock') AS ca(dr)
        CROSS APPLY ca.dr.nodes('//waiter-list/waiter') AS w(l)
        CROSS APPLY ca.dr.nodes('//owner-list/owner') AS o(l)
		OPTION ( RECOMPILE );


		/*This parses rid locks*/
        INSERT #deadlock_owner_waiter
        SELECT      ca.dr.value('@dbid', 'BIGINT') AS database_id,
                    ca.dr.value('@objectname', 'NVARCHAR(256)') AS object_name,
                    ca.dr.value('@mode', 'NVARCHAR(256)') AS lock_mode,
                    w.l.value('@id', 'NVARCHAR(256)') AS waiter_id,
                    w.l.value('@mode', 'NVARCHAR(256)') AS waiter_mode,
                    o.l.value('@id', 'NVARCHAR(256)') AS owner_id,
                    o.l.value('@mode', 'NVARCHAR(256)') AS owner_mode
        FROM        #deadlock_resource AS dr
        CROSS APPLY dr.resource_xml.nodes('//resource-list/ridlock') AS ca(dr)
        CROSS APPLY ca.dr.nodes('//waiter-list/waiter') AS w(l)
        CROSS APPLY ca.dr.nodes('//owner-list/owner') AS o(l)
		OPTION ( RECOMPILE );

		/*Get rid of nonsense*/
		DELETE dow
		FROM #deadlock_owner_waiter AS dow
		WHERE dow.owner_id = dow.waiter_id;

		/*Add some nonsense*/
		ALTER TABLE #deadlock_process
		ADD waiter_mode	NVARCHAR(256),
			owner_mode NVARCHAR(256),
			is_victim AS CONVERT(BIT, CASE WHEN id = victim_id THEN 1 ELSE 0 END);

		/*Update some nonsense*/
		UPDATE dp
		SET dp.owner_mode = dow.owner_mode
		FROM #deadlock_process AS dp
		JOIN #deadlock_owner_waiter AS dow
		ON dp.id = dow.owner_id
		WHERE dp.is_victim = 0;

		UPDATE dp
		SET dp.waiter_mode = dow.waiter_mode
		FROM #deadlock_process AS dp
		JOIN #deadlock_owner_waiter AS dow
		ON dp.victim_id = dow.waiter_id
		WHERE dp.is_victim = 1;


		/*Begin checks based on parsed values*/

		/*Check 1 is deadlocks by database*/
		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 	
		SELECT 1 AS check_id, 
			   DB_NAME(dp.database_id) AS database_name, 
			   '-' AS object_name,
			   'Total database locks' AS finding_group,
			   'This database had ' 
				+ CONVERT(NVARCHAR(20), COUNT_BIG(DISTINCT dp.event_date)) 
				+ ' deadlocks.'
        FROM   #deadlock_process AS dp
		GROUP BY DB_NAME(dp.database_id)
		OPTION ( RECOMPILE );

		/*Check 2 is deadlocks by object*/

		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 	
		SELECT 2 AS check_id, 
			   DB_NAME(dow.database_id) AS database_name, 
			   dow.object_name AS object_name,
			   'Total object deadlocks' AS finding_group,
			   'This object was involved in ' 
				+ CONVERT(NVARCHAR(20), COUNT_BIG(DISTINCT dow.object_name))
				+ ' deadlock(s).'
        FROM   #deadlock_owner_waiter AS dow
		GROUP BY DB_NAME(dow.database_id), dow.object_name
		OPTION ( RECOMPILE );
		

		/*Check 3 looks for Serializable locking*/
		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 
		SELECT 3 AS check_id,
			   DB_NAME(dp.database_id) AS database_name,
			   '-' AS object_name,
			   'Serializable locking' AS finding_group,
			   'This database has had ' + 
			   CONVERT(NVARCHAR(20), COUNT_BIG(*)) +
			   ' instances of serializable deadlocks.'
			   AS finding
		FROM #deadlock_process AS dp
		WHERE dp.isolation_level LIKE 'serializable%'
		GROUP BY DB_NAME(dp.database_id)
		OPTION ( RECOMPILE );


		/*Check 4 looks for Repeatable Read locking*/
		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 
		SELECT 4 AS check_id,
			   DB_NAME(dp.database_id) AS database_name,
			   '-' AS object_name,
			   'Repeatable Read locking' AS finding_group,
			   'This database has had ' + 
			   CONVERT(NVARCHAR(20), COUNT_BIG(*)) +
			   ' instances of repeatable read deadlocks.'
			   AS finding
		FROM #deadlock_process AS dp
		WHERE dp.isolation_level LIKE 'repeatable read%'
		GROUP BY DB_NAME(dp.database_id)
		OPTION ( RECOMPILE );


		/*Check 5 breaks down app, host, and login information*/
		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 
		SELECT 5 AS check_id,
			   DB_NAME(dp.database_id) AS database_name,
			   '-' AS object_name,
			   'Login, App, and Host locking' AS finding_group,
			   'This database has had ' + 
			   CONVERT(NVARCHAR(20), COUNT_BIG(DISTINCT dp.id)) +
			   ' instances of deadlocks involving the login ' +
			   ISNULL(dp.login_name, 'UNKNOWN') + 
			   ' from the application ' + 
			   ISNULL(dp.client_app, 'UNKNOWN') + 
			   ' on host ' + 
			   ISNULL(dp.host_name, 'UNKNOWN')
			   AS finding
		FROM #deadlock_process AS dp
		GROUP BY DB_NAME(dp.database_id), dp.login_name, dp.client_app, dp.host_name
		OPTION ( RECOMPILE );


		/*Check 6 breaks down the types of locks (object, page, key, etc.)*/
		WITH lock_types AS (
				SELECT DB_NAME(dp.database_id) AS database_name,
					   dow.object_name, 
					   SUBSTRING(dp.wait_resource, 1, CHARINDEX(':', dp.wait_resource) -1) AS lock,
					   CONVERT(NVARCHAR(20), COUNT_BIG(DISTINCT dp.id)) AS lock_count
				FROM #deadlock_process AS dp 
				JOIN #deadlock_owner_waiter AS dow
				ON dp.id = dow.owner_id
				GROUP BY DB_NAME(dp.database_id), SUBSTRING(dp.wait_resource, 1, CHARINDEX(':', dp.wait_resource) - 1), dow.object_name
							)	
		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 
		SELECT DISTINCT 6 AS check_id,
			   lt.database_name,
			   lt.object_name,
			   'Types of locks by object' AS finding_group,
			   'This object has had ' +
			   STUFF((SELECT DISTINCT N', ' + lt2.lock_count + ' ' + lt2.lock
									FROM lock_types AS lt2
									WHERE lt2.database_name = lt.database_name
									AND lt2.object_name = lt.object_name
									FOR XML PATH(N''), TYPE).value(N'.[1]', N'NVARCHAR(MAX)'), 1, 1, N'')
			   + ' locks'
		FROM lock_types AS lt
		OPTION ( RECOMPILE );


		/*Check 7 gives you more info queries for sp_BlitzCache & BlitzQueryStore*/
		WITH deadlock_stack AS (
			SELECT  DISTINCT
					ds.id,
					ds.sql_handle,
					ds.proc_name,
					PARSENAME(ds.proc_name, 3) AS database_name,
					PARSENAME(ds.proc_name, 2) AS schema_name,
					PARSENAME(ds.proc_name, 1) AS proc_only_name
			FROM #deadlock_stack AS ds	
					)
		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 
		SELECT DISTINCT 7 AS check_id,
			   DB_NAME(dow.database_id) AS database_name,
			   ds.proc_name AS object_name,
			   'More Info - Query' AS finding_group,
			   'EXEC sp_BlitzCache ' +
					CASE WHEN ds.proc_name = 'adhoc'
						 THEN ' @OnlySqlHandles = ' + 
							  QUOTENAME(ds.sql_handle, '''')
						 ELSE '@StoredProcName = ' + 
						       QUOTENAME(ds.proc_only_name, '''')
					END +
					';' AS finding
		FROM deadlock_stack AS ds
		JOIN #deadlock_owner_waiter AS dow
		ON dow.owner_id = ds.id
		OPTION ( RECOMPILE );

		IF @ProductVersionMajor >= 13
		BEGIN
		
		WITH deadlock_stack AS (
			SELECT  DISTINCT
					ds.id,
					ds.sql_handle,
					ds.proc_name,
					PARSENAME(ds.proc_name, 3) AS database_name,
					PARSENAME(ds.proc_name, 2) AS schema_name,
					PARSENAME(ds.proc_name, 1) AS proc_only_name
			FROM #deadlock_stack AS ds	
					)
		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 
		SELECT DISTINCT 7 AS check_id,
			   DB_NAME(dow.database_id) AS database_name,
			   ds.proc_name AS object_name,
			   'More Info - Query' AS finding_group,
			   'EXEC sp_BlitzQueryStore ' 
			   + '@DatabaseName = ' 
			   + QUOTENAME(ds.database_name, '''')
			   + ', '
			   + '@StoredProcName = ' 
			   + QUOTENAME(ds.proc_only_name, '''')
			   + ';' AS finding
		FROM deadlock_stack AS ds
		JOIN #deadlock_owner_waiter AS dow
		ON dow.owner_id = ds.id
		WHERE ds.proc_name <> 'adhoc'
		OPTION ( RECOMPILE );
		END;
		

		/*Check 8 gives you stored proc deadlock counts*/
		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding )
		SELECT 8 AS check_id,
			   DB_NAME(dp.database_id) AS database_name,
			   ds.proc_name, 
			   'Stored Procedure Deadlocks',
			   'The stored procedure ' 
			   + PARSENAME(ds.proc_name, 2)
			   + '.'
			   + PARSENAME(ds.proc_name, 1)
			   + ' has been involved in '
			   + CONVERT(NVARCHAR(10), COUNT_BIG(DISTINCT ds.id))
			   + ' deadlocks.'
		FROM #deadlock_stack AS ds
		JOIN #deadlock_process AS dp
		ON dp.id = ds.id
		WHERE ds.proc_name <> 'adhoc'
		GROUP BY DB_NAME(dp.database_id), ds.proc_name
		OPTION(RECOMPILE);


		/*Check 9 gives you more info queries for sp_BlitzIndex */
		WITH bi AS (
				SELECT  DISTINCT
						dow.object_name,
						PARSENAME(dow.object_name, 3) AS database_name,
						PARSENAME(dow.object_name, 2) AS schema_name,
						PARSENAME(dow.object_name, 1) AS table_name
				FROM #deadlock_owner_waiter AS dow
					)
		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 
		SELECT 9 AS check_id,	
				bi.database_name,
				bi.schema_name + '.' + bi.table_name,
				'More Info - Table' AS finding_group,
				'EXEC sp_BlitzIndex ' + 
				'@DatabaseName = ' + QUOTENAME(bi.database_name, '''') + 
				', @SchemaName = ' + QUOTENAME(bi.schema_name, '''') + 
				', @TableName = ' + QUOTENAME(bi.table_name, '''') +
				';'	 AS finding
		FROM bi
		OPTION ( RECOMPILE );

		/*Check 10 gets total deadlock wait time per object*/
		WITH chop AS (
				SELECT SUBSTRING(dp.wait_resource,
								CHARINDEX(':', dp.wait_resource, CHARINDEX(':', dp.wait_resource)) + 2,
								LEN(dp.wait_resource)
								) AS chopped, 
						dp.database_id,
						SUM(dp.wait_time) AS wait_time
				FROM #deadlock_process AS dp
				GROUP BY dp.wait_resource, dp.database_id
					),
			suey AS (
				SELECT SUBSTRING(c.chopped,
								CHARINDEX(':', c.chopped) + 1,
								CHARINDEX(':', c.chopped, CHARINDEX(':', c.chopped) + 1)
								- 1 - CHARINDEX(':', c.chopped)
								) AS obj_id,
						c.database_id,
						c.wait_time
				FROM chop AS c
					),
			chopsuey AS (
				SELECT *, 
				DB_NAME(s.database_id) AS database_name,
				OBJECT_SCHEMA_NAME(s.obj_id, s.database_id) AS sch_name,
				OBJECT_NAME(s.obj_id, s.database_id) AS tbl_name,
				OBJECT_SCHEMA_NAME(s.obj_id, s.database_id) 
				+ N'.'
				+ OBJECT_NAME(s.obj_id, s.database_id) AS object_name,
				CONVERT(VARCHAR(10), (s.wait_time / 1000) / 86400) AS wait_days,
				CONVERT(VARCHAR(20), DATEADD(SECOND, (s.wait_time / 1000), 0), 108) AS wait_time_hms
				FROM suey AS s
						)
				INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 
				SELECT 10 AS check_id,
						cs.database_name,
						cs.object_name,
						'Total object deadlock wait time' AS finding_group,
						'This object has had ' 
						+ CONVERT(VARCHAR(10), cs.wait_days) 
						+ ':' + CONVERT(VARCHAR(20), cs.wait_time_hms, 108)
						+ ' [d/h/m/s] of deadlock wait time.' AS finding
				FROM chopsuey AS cs
				WHERE cs.object_name IS NOT NULL
				OPTION ( RECOMPILE );

		/*Check 11 gets total deadlock wait time per database*/
		WITH wait_time AS (
						SELECT DB_NAME(dp.database_id) AS database_name,
							   SUM(CONVERT(BIGINT, dp.wait_time)) AS total_wait_time_ms
						FROM #deadlock_process AS dp
						GROUP BY DB_NAME(dp.database_id)
						  )
		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 
		SELECT 11 AS check_id,
				wt.database_name,
				'-' AS object_name,
				'Total database deadlock wait time' AS finding_group,
				'This database has had ' 
				+ CONVERT(VARCHAR(10), (SUM(DISTINCT wt.total_wait_time_ms) / 1000) / 86400) 
				+ ':' + CONVERT(VARCHAR(20), DATEADD(SECOND, (SUM(DISTINCT wt.total_wait_time_ms) / 1000), 0), 108)
				+ ' [d/h/m/s] of deadlock wait time.'
		FROM wait_time AS wt
		GROUP BY wt.database_name
		OPTION ( RECOMPILE );


		/*Thank you goodnight*/
		INSERT #deadlock_findings ( check_id, database_name, object_name, finding_group, finding ) 
		VALUES ( -1, 
				 N'sp_BlitzLock ' + CAST(CONVERT(DATETIME, @VersionDate, 102) AS VARCHAR(100)), 
				 N'SQL Server First Responder Kit', 
				 N'http://FirstResponderKit.org/', 
				 N'To get help or add your own contributions, join us at http://FirstResponderKit.org.');

		
		WITH deadlocks
		AS ( SELECT dp.event_date,
		            dp.id,
		            dp.database_id,
		            dp.log_used,
		            dp.wait_resource,
		            CONVERT(
		                XML,
		                STUFF((   SELECT DISTINCT NCHAR(10) 
										+ N' <objects>' 
										+ ISNULL(dow.object_name, N'') 
										+ N'</objects> ' AS object_name
		                        FROM   #deadlock_owner_waiter AS dow
		                        WHERE  dp.id = dow.owner_id
		                               OR dp.id = dow.waiter_id
		                        FOR XML PATH(N''), TYPE ).value(N'.[1]', N'NVARCHAR(4000)'),
		                    1, 1, N'')) AS object_names,
		            dp.wait_time,
		            dp.transaction_name,
		            dp.last_tran_started,
		            dp.last_batch_started,
		            dp.last_batch_completed,
		            dp.lock_mode,
		            dp.transaction_count,
		            dp.client_app,
		            dp.host_name,
		            dp.login_name,
		            dp.isolation_level,
		            dp.process_xml.value('(//process/inputbuf/text())[1]', 'NVARCHAR(MAX)') AS inputbuf,
		            ROW_NUMBER() OVER ( PARTITION BY dp.event_date, dp.id ORDER BY dp.event_date ) AS dn,
					dp.is_victim,
					ISNULL(dp.owner_mode, '-') AS owner_mode,
					ISNULL(dp.waiter_mode, '-') AS waiter_mode
		     FROM   #deadlock_process AS dp )
		SELECT d.event_date,
		       DB_NAME(d.database_id) AS database_name,
		       CONVERT(XML, N'<inputbuf>' + d.inputbuf + N'</inputbuf>') AS query,
		       d.object_names,
		       d.isolation_level,
			   d.is_victim,
			   d.owner_mode,
			   d.waiter_mode,
		       d.transaction_count,
		       d.login_name,
		       d.host_name,
		       d.client_app,
		       d.wait_time,
			   d.log_used,
		       d.last_tran_started,
		       d.last_batch_started,
		       d.last_batch_completed,
		       d.transaction_name
		FROM   deadlocks AS d
		WHERE  d.dn = 1
		ORDER BY d.event_date, d.last_batch_started, d.last_tran_started;



		SELECT df.check_id, df.database_name, df.object_name, df.finding_group, df.finding
		FROM #deadlock_findings AS df
		ORDER BY df.check_id
		OPTION ( RECOMPILE );


        IF @Debug = 1
            BEGIN

                SELECT '#deadlock_data' AS table_name, *
                FROM   #deadlock_data AS dd
				OPTION ( RECOMPILE );

                SELECT '#deadlock_resource' AS table_name, *
                FROM   #deadlock_resource AS dr
				OPTION ( RECOMPILE );

                SELECT '#deadlock_owner_waiter' AS table_name, *
                FROM   #deadlock_owner_waiter AS dow
				OPTION ( RECOMPILE );

                SELECT '#deadlock_process' AS table_name, *
                FROM   #deadlock_process AS dp
				OPTION ( RECOMPILE );

                SELECT '#deadlock_stack' AS table_name, *
                FROM   #deadlock_stack AS ds
				OPTION ( RECOMPILE );
				
            END; -- End debug

    END; --Final End

GO

