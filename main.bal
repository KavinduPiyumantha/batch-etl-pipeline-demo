import ballerina/log;
import ballerina/sql;
import ballerina/time;
import ballerinax/h2.driver as _;
import ballerinax/java.jdbc;
import ballerina/io;

final jdbc:Client dbClient = check new (url = "jdbc:h2:file:./database/loandatabase", user = "test", password = "test");

public function main() returns error? {
    check initDB();
    [LoanRequest[], LoanApproval[]] extractedData = check extract();
    [Loan[], BranchPerformance[], RegionPerformance[]] transformResult = transform(extractedData[0], extractedData[1]);
    check load(transformResult);
}

function extract() returns [LoanRequest[], LoanApproval[]]|error {
    log:printInfo("BEGIN: extract data from the sftp server");

    string loanRequestFile = "resources/loan_request_2024_03_22.csv";
    string loanApprovalsFile = "resources/approved_loans_2024_03_22.csv";

    // Reads the previously-saved CSV file as a `record[]`.
    LoanRequest[] readLoanRequests = check io:fileReadCsv(loanRequestFile);
    LoanApproval[] readLoanApprovals = check io:fileReadCsv(loanApprovalsFile);
    io:println(readLoanRequests);
    io:println(readLoanApprovals);

    log:printInfo("END: extract data from the sftp server");
    return [readLoanRequests, readLoanApprovals];
}

function transform(LoanRequest[] loanRequests, LoanApproval[] loanApprovals)
    returns [Loan[], BranchPerformance[], RegionPerformance[]] {
    log:printInfo("START: transform data");

    // Join `LoanRequest` and `LoanApproval` arrays to get the approved loans
    Loan[] approvedLoans = from LoanRequest lr in loanRequests
                           join LoanApproval la in loanApprovals
                           on lr.loanRequestId equals la.loanRequestId
                           select transformLoanRequest(lr, la);

    // Group the `approvedLoans` by branch and loan type to create `BranchPerformance` records
    BranchPerformance[] branchPerformance = from var {branch, loanType, grantedAmount, interest}
                                            in approvedLoans
                                            group by branch, loanType
                                            select {
                                                id: generateId(),
                                                branch,
                                                loanType,
                                                totalGrants: sum(grantedAmount),
                                                totalInterest: sum(interest),
                                                date: todayString()
                                            };

    // Group the `approvedLoans` by region, loanType, date, dayOfWeek to create `RegionPerformance` records
    RegionPerformance[] regionPerformance = from var {region, loanType, date, dayOfWeek, grantedAmount, interest}
                                            in approvedLoans
                                            group by region, loanType, date, dayOfWeek
                                            select {
                                                id: generateId(),
                                                region,
                                                loanType,
                                                date,
                                                dayOfWeek,
                                                totalGrants: sum(grantedAmount),
                                                totalInterest: sum(interest)
                                            };

    log:printInfo("END: transform data");
    return [approvedLoans, branchPerformance, regionPerformance];
}

function transformLoanRequest(LoanRequest loanRequest, LoanApproval loanApproval) returns Loan {
    log:printInfo(string `START: transform loan request: ${loanRequest.loanRequestId}`);

    var {loanRequestId, amount, loanType, datetime, period, branch, status} = loanRequest;
    var {grantedAmount, interest, period: approvedPeriod} = loanApproval;

    // Date time related operations
    time:Date date = fromUtcStringToDate(datetime, USA_UTC_OFFSET_IN_SECONDS);
    string dateString = fromDateToString(date);
    DayOfWeek dayOfWeek = getDayOfWeek(date);

    // Categorize branch by region
    string region = getRegion(branch);

    // Categorization of loans by amount and type
    LoanCatergotyByAmount loanCatergoryByAmount = getLoanCategoryByAmount(amount, loanType);

    // Calculate total interest
    decimal totalInterest = interest*grantedAmount;

    // Get the loan status
    LoanStatus loanStatus = getLoanStatus(status);

    // Get the loan type
    LoanType 'type = getLoanType(loanType);

    log:printInfo(string `END: transform loan request: ${loanRequest.loanRequestId}`);
    return {
        loanRequestId,
        amount,
        loanType: 'type,
        datetime,
        period,
        branch,
        status: loanStatus,
        dayOfWeek,
        region,
        date: dateString,
        grantedAmount,
        interest: totalInterest,
        approvedPeriod,
        loanCatergoryByAmount
    };
}

function load([Loan[], BranchPerformance[], RegionPerformance[]] transformResult) returns error? {
    log:printInfo("START: loading data");
    check loadLoan(transformResult[0]);
    check loadBranchPerformance(transformResult[1]);
    check loadRegionPerformance(transformResult[2]);
    log:printInfo("END: loading data");
}

function loadRegionPerformance(RegionPerformance[] data) returns error? {
    sql:ParameterizedQuery[] insertQueries = from RegionPerformance rp in data
        select `INSERT INTO RegionPerformance 
                (id, region, loanType, date, dayOfWeek, totalGrants, totalInterest) 
                VALUES (${rp.id}, ${rp.region}, ${rp.loanType}, 
                ${rp.date}, ${rp.dayOfWeek}, ${rp.totalGrants}, ${rp.totalInterest})`;
    _ = check dbClient->batchExecute(insertQueries);
}

function loadBranchPerformance(BranchPerformance[] data) returns error? {
    sql:ParameterizedQuery[] insertQueries = from BranchPerformance bp in data
        select `INSERT INTO BranchPerformance (id, branch, loanType, totalGrants, totalInterest, date) 
                VALUES (${bp.id}, ${bp.branch}, ${bp.loanType}, ${bp.totalGrants}, ${bp.totalInterest}, ${bp.date})`;
    _ = check dbClient->batchExecute(insertQueries);
}

function loadLoan(Loan[] data) returns error? {
    sql:ParameterizedQuery[] insertQueries = from Loan loan in data
        select `INSERT INTO Loan (loanRequestId, amount, period, branch, status, loanType, 
        datetime, dayOfWeek, region, date, interest, grantedAmount, approvedPeriod, loanCatergoryByAmount) 
        VALUES (${loan.loanRequestId}, ${loan.amount}, ${loan.period}, ${loan.branch}, ${loan.status}, ${loan.loanType}, ${loan.datetime}, ${loan.dayOfWeek}, ${loan.region}, ${loan.date}, ${loan.interest}, ${loan.grantedAmount}, ${loan.approvedPeriod}, ${loan.loanCatergoryByAmount})`;
    _ = check dbClient->batchExecute(insertQueries);
}

function getRegion(string branch) returns string {
    return branchToRegionMap[branch] ?: "";
}