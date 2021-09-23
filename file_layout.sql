-- Verify that the stored procedure does not already exist.  
IF OBJECT_ID ( 'usp_GetErrorInfo', 'P' ) IS NOT NULL   
    DROP PROCEDURE usp_GetErrorInfo;  
GO  
-- Create procedure to retrieve error information.  
CREATE PROCEDURE usp_GetErrorInfo  
AS  
SELECT  
    ERROR_NUMBER() AS ErrorNumber  
    ,ERROR_SEVERITY() AS ErrorSeverity  
    ,ERROR_STATE() AS ErrorState  
    ,ERROR_PROCEDURE() AS ErrorProcedure  
    ,ERROR_LINE() AS ErrorLine  
    ,ERROR_MESSAGE() AS ErrorMessage;  
GO  

CREATE TABLE #Disksetup (
	 DBName sysname
	 ,DBfilename VARCHAR(MAX)
	,Filepath VARCHAR(MAX)
	,Size BIGINT
	) 

DECLARE @str VARCHAR(500)
SET @str =  'USE ? SELECT ''?'', SF.name, SF.filename, SF.size FROM sys.sysfiles SF'
BEGIN TRY
	INSERT INTO #Disksetup 
	EXEC sp_MSforeachdb @command1=@str
END TRY
BEGIN CATCH  
    EXECUTE usp_GetErrorInfo;  
END CATCH;
