/*----------------------------------------------------------------------------------------------------------------------------------
	The sample code below was created with the intention of demonstrating a technique I've developed to enhance search performance.
	 
	Objective: 
		To find users from a specific list of users.
		For example: Withing a social network/graph, search for "mark" within my list of friends.
	
		Conventionally, a typical data structure to faciliate this type of search in a RDBMS requires a table to hold the user 
		to friends relationships, and another table that stores the searchable terms for the friends. 
		The typical search process would follow a pattern such as this:
			- Fetch all friends within the "UserFriends" table
			- With the entire list of FriendIDs, seek into the "UsersInfo" table to if any of their name parts matches the input search string
			
	Bitmask Filtering Technique:
		What I've done is add a bitmask column in the "UserFriends" which represents all starting characters for the searchable terms 
		of each friend. The purpose of this bitmask is to pre-filter out friends that do not have a searchable terms that starts 
		with he same character(s) as the input search string. Thus, negating the need to seek into the "UserInfo" table to see if there is match.
	
		For example:
			- My UserID is 1
			- My friend Joe Smith UserID is 2
			- Joe's email is abcde@yahoo.com
			
			The searchable terms for Joe is "Joe", "Joe Smith", "Smith", and "abcde@yahoo.com"
			The bitmask would look like this:
				Alhpa:			 a b c d e f g h i j k l m n o p q r s t u v w x y z
				Binary:			 1 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0
							     0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0
				Bitmask Decimal: 33620096
			
			And the record in the UserFriend would look like this:
				UserID		FriendID	FilterBitmask
					 1			   2	     33620096
			
			So if I'm searching for "robert" within my friends, 
			I know that UserID 2 would not be a candidate just by doing a simple bitwise operation
				 "r" in my bitmask scheme =  0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 0 0 0 0 0 0 0 =  256 
				 and 33620096 &(bitwise AND) 256 = 0
			
			Ultimately, this technique allows for pre-filtering of records that would never be a match in the "UserInfo" table, 
			which is expenseive part of the operation. In SQL Server, scanning the "UserFriends" table and performing a bitwise operation 
			is very cheap compared to the multiple times a nested loop must be performed for each FriendID in the "UserInfo" table.
			
	Pros:
		Enhanced search performance. The benefit is not that pronounced in my example below, 
		but imagine an environment where I may have a million friends. My real world implementation of this algorithm uses 768 bits,
		bucketizing searchable terms in an even distribution. I was able to filter out 98% + friends on average, which increased the
		overall performance by a huge margin. If I had 1 million friends, the search operation only needed seek 20,000 times into 
		the "UsrsInfo" table
	
	Cons:
		- Extra storage space is required to store the bitmasks. 
			ONLY FOR SQL Server 2008 Enterprise: 
				With SQL Row Compression, the storage increased can be tapered significantly if the bitmask is broken out into 
				multiple bigint columns. In SQL 2008, if a column is NULL, it will only require 1 bit instead of the full space allocation 
				for integer types in previous versions of SQL.
				
		- The cost of updating these bitmask values whenver users change their searchable terms. 
		
----------------------------------------------------------------------------------------------------------------------------------*/

/*----------------------------------------------------------------------------------------------------------------------------------
	 DDLs
----------------------------------------------------------------------------------------------------------------------------------*/
	IF EXISTS (SELECT * FROM dbo.sysobjects WHERE id = OBJECT_ID(N'[dbo].[Users]') AND OBJECTPROPERTY(id, N'IsUserTable') = 1)
	DROP TABLE [dbo].[Users]
	GO
	IF EXISTS (SELECT * FROM dbo.sysobjects WHERE id = OBJECT_ID(N'[dbo].[UserFriends]') AND OBJECTPROPERTY(id, N'IsUserTable') = 1)
	DROP TABLE [dbo].[UserFriends]
	GO
	IF EXISTS (SELECT * FROM dbo.sysobjects WHERE id = OBJECT_ID(N'[dbo].[BitBoundaries]') AND OBJECTPROPERTY(id, N'IsUserTable') = 1)
	DROP TABLE [dbo].[BitBoundaries]
	GO

	CREATE TABLE dbo.Users 
	(
		 UserID     INT            NOT NULL
		,SearchTerm VARCHAR (200)  NOT NULL
		,MatchType	VARCHAR (32)   NOT NULL
		,CONSTRAINT PK_Users PRIMARY KEY (UserID, SearchTerm, MatchType)
	);
	GO

	CREATE TABLE dbo.UserFriends
	(
		 UserID INT NOT NULL
		,FriendID INT NOT NULL
		,FilterBitmask INT
		,CONSTRAINT PK_UserFriends PRIMARY KEY (UserID, FriendID) 
	)
	GO

	CREATE TABLE [dbo].[BitBoundaries] 
	(
		[LBound]  CHAR(1) NOT NULL,
		[Bitmask] INT NOT NULL
		,CONSTRAINT PK_BitBoundaries PRIMARY KEY(LBound)
	);
	GO

/*----------------------------------------------------------------------------------------------------------------------------------
	 Populate User table
----------------------------------------------------------------------------------------------------------------------------------*/
	-- USER 86
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Joe', 'FirstName', 86
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Smith', 'LastName', 86
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Joe Smith', 'FullName', 86
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'abcde@yahoo.com', 'email', 86
	-- USER 1
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Mark', 'FirstName', 1
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Lee', 'LastName', 1
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Mark Lee', 'FullName', 1
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'marklee@yahoo.com', 'email', 1
	-- USER 2
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Tomoji', 'FirstName', 2
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Kato', 'LastName', 2
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Tomoji Kato', 'FullName', 2
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'kendomaster@yahoo.com', 'email', 2
	-- USER 3
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Bruce', 'FirstName', 3
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Ree', 'LastName', 3
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'Bruce Ree', 'FullName', 3
	INSERT INTO dbo.Users (SearchTerm, MatchType, UserID) SELECT 'moo@yahoo.com', 'email', 3
	GO

/*----------------------------------------------------------------------------------------------------------------------------------
	 Populate BitBoundaries table
----------------------------------------------------------------------------------------------------------------------------------*/
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'a',1
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'b',2
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'c',4
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'd',8
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'e',16
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'f',32
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'g',64
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'h',128
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'i',256
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'j',512
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'k',1024
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'l',2048
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'm',4096
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'n',8192
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'o',16384
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'p',32768
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'q',65536
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'r',131072
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 's',262144
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 't',524288
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'u',1048576
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'v',2097152
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'w',4194304
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'x',8388608
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'y',16777216
	INSERT INTO dbo.BitBoundaries(Lbound,Bitmask) SELECT 'z',33554432
	GO

/*----------------------------------------------------------------------------------------------------------------------------------
	 Populate UserFriends table
----------------------------------------------------------------------------------------------------------------------------------*/
	INSERT INTO UserFriends(UserID,FriendID,FilterbitMask) SELECT 86,1,NULL
	INSERT INTO UserFriends(UserID,FriendID,FilterbitMask) SELECT 86,2,NULL
	INSERT INTO UserFriends(UserID,FriendID,FilterbitMask) SELECT 86,3,NULL
	GO

	-- now update the bitmasks column
	UPDATE uf
	SET FilterbitMask = 
		(
		SELECT SUM(DISTINCT Bitmask)
		FROM
			(
			SELECT 
				 UserID
				,(
					SELECT TOP 1 Bitmask 
					FROM dbo.BitBoundaries 
					WHERE LBound <= u.searchterm 
					ORDER BY lbound DESC
				 ) AS Bitmask
			FROM dbo.Users u
			WHERE UserID = uf.FriendID
			) t1
		)
	FROM UserFriends uf
	GO

/*----------------------------------------------------------------------------------------------------------------------------------
	 Search within friends WITH bitmask filtering
----------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE 
		 @InputSearchTerm VARCHAR(200)
		,@InputBitmask INT 
		,@InputUserID INT
		
	SELECT 
		 @InputUserID = 86
		,@InputSearchTerm = 'Tomoji'

	SELECT TOP 1 
		@InputBitmask = Bitmask
	FROM dbo.BitBoundaries
	WHERE lbound <= @InputSearchTerm
	ORDER BY lbound DESC

	SET STATISTICS IO ON 

	SELECT
		 u.UserID
		,u.MatchType
		,u.SearchTerm
	FROM 
		dbo.UserFriends uf
		INNER JOIN dbo.Users u on (uf.FriendID = u.UserID)
	WHERE 
		uf.FilterbitMask & @InputBitmask = @InputBitmask
		AND uf.UserID = @InputUserID
		AND u.SearchTerm = @InputSearchTerm
	OPTION (FORCE ORDER) -- this query hint is required to simulate a real production environment with much more data
	
	GO
	/*----------------------------------------------------------------------------------------------------------------------------------
		 IO Results:
		 Table 'Users'. Scan count 1, logical reads 2
		 There was only 1 seek operation into the Users table.
	----------------------------------------------------------------------------------------------------------------------------------*/

/*----------------------------------------------------------------------------------------------------------------------------------
	 Search within friends WITH NO bitmask filtering
----------------------------------------------------------------------------------------------------------------------------------*/
	DECLARE 
		 @InputSearchTerm VARCHAR(200)
		,@InputUserID INT
		
	SELECT 
		 @InputUserID = 86
		,@InputSearchTerm = 'Tomoji'

	SELECT
		 u.UserID
		,u.MatchType
		,u.SearchTerm
	FROM 
		dbo.UserFriends uf
		INNER JOIN dbo.Users u on (uf.FriendID = u.UserID)
	WHERE 
		uf.UserID = @InputUserID
		AND u.SearchTerm = @InputSearchTerm
	OPTION (FORCE ORDER) -- this query hint is required to simulate a real production environment with much more data
	
	GO
	/*----------------------------------------------------------------------------------------------------------------------------------
		 IO Result:
		 Table 'Users'. Scan count 3, logical reads 6
		 There were 3 seek operations into the Users table. 
	----------------------------------------------------------------------------------------------------------------------------------*/